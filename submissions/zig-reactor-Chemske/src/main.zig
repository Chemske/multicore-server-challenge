const std = @import("std");
const c = std.c;
const events = @import("events.zig");
const http = @import("http.zig");
const pg = @import("postgres.zig");
const requests = @import("requests.zig");
const bcrypt = @import("bcrypt_pool.zig");

const max_clients = 256;
const max_input = http.max_head + http.max_body + 4096;
const database_bit: u64 = 1 << 31;
const database_connections = @import("build_options").database_connections;
const listener_token = 1;
const worker_token = 2;
const Database = struct {
    connection: ?*pg.Conn = null,
    opening: ?pg.Connector = null,
    active: ?*requests.Task = null,
    active_since: i64 = 0,
    retry_at: i64 = 0,
    retry_delay: i64 = 250,
    generation: u32 = 1,
    fd: c_int = -1,
};
const State = enum { closed, reading, queued, database, hashing, writing };
const Client = struct {
    fd: c_int = -1,
    generation: u32 = 1,
    state: State = .closed,
    input: std.ArrayList(u8) = .empty,
    output: []u8 = &.{},
    sent: usize = 0,
    keep_alive: bool = true,
    last_activity: i64 = 0,
    sequence: u64 = 0,
    task: ?*requests.Task = null,
};

const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: events.Loop,
    listener: c_int,
    databases: []Database,
    database_url: [*:0]const u8,
    clients: []Client,
    pool: *bcrypt.Pool,
    secret: []const u8,
    sequence: u64 = 0,

    fn now(self: *Server) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn token(self: *Server, index: usize) u64 {
        return (@as(u64, self.clients[index].generation) << 32) | (index + 3);
    }

    fn wallTime(self: *Server) i64 {
        return @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), 1000);
    }

    fn closeClient(self: *Server, index: usize) void {
        const client = &self.clients[index];
        if (client.fd < 0) return;
        if (client.task) |task| {
            // Active database work and bcrypt completions retain their own task lifetime.
            if (client.state == .queued) task.destroy(self.allocator);
        }
        _ = c.close(client.fd);
        client.input.deinit(self.allocator);
        if (client.output.len != 0) self.allocator.free(client.output);
        client.* = .{ .generation = client.generation +% 1 };
    }

    fn acceptClients(self: *Server) !void {
        // A per-turn budget keeps a burst of new sockets from starving database progress.
        for (0..64) |_| {
            const fd = c.accept(self.listener, null, null);
            if (fd < 0) {
                if (c.errno(fd) == .INTR) continue;
                if (c.errno(fd) == .AGAIN) return;
                return error.Accept;
            }
            const slot = for (self.clients, 0..) |client, i| {
                if (client.state == .closed) break i;
            } else {
                _ = c.close(fd);
                continue;
            };
            events.nonblocking(fd) catch {
                _ = c.close(fd);
                continue;
            };
            events.noSigpipe(fd) catch {
                _ = c.close(fd);
                continue;
            };
            self.clients[slot].fd = fd;
            self.clients[slot].state = .reading;
            self.clients[slot].last_activity = self.now();
            self.loop.watch(fd, self.token(slot), true, false) catch self.closeClient(slot);
        }
    }

    fn respond(self: *Server, index: usize, status: u16, body: []const u8) !void {
        const client = &self.clients[index];
        const reason: []const u8 = switch (status) {
            200 => "OK",
            201 => "Created",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            413 => "Content Too Large",
            422 => "Unprocessable Content",
            431 => "Request Header Fields Too Large",
            505 => "HTTP Version Not Supported",
            else => "Service Unavailable",
        };
        client.output = if (status == 204)
            try std.fmt.allocPrint(self.allocator, "HTTP/1.1 204 No Content\r\nConnection: {s}\r\n\r\n", .{if (client.keep_alive) @as([]const u8, "keep-alive") else "close"})
        else
            try std.fmt.allocPrint(self.allocator, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n{s}", .{ status, reason, body.len, if (client.keep_alive) @as([]const u8, "keep-alive") else "close", body });
        client.sent = 0;
        client.state = .writing;
        client.last_activity = self.now();
        try self.loop.watch(client.fd, self.token(index), false, true);
    }

    fn processInput(self: *Server, index: usize) !void {
        const client = &self.clients[index];
        switch (http.parse(client.input.items)) {
            .more => {},
            .bad => |status| {
                client.keep_alive = false;
                try self.respond(index, status, "{\"errors\":{\"body\":[\"invalid HTTP request\"]}}");
            },
            .request => |request| {
                client.keep_alive = request.keep_alive;
                // Request fields borrow this buffer. Copy them before compacting pipelined bytes.
                if (request.route == .unknown) {
                    consume(client, request.consumed);
                    try self.respond(index, 404, "{\"errors\":{\"body\":[\"route not implemented\"]}}");
                    return;
                }
                const task = requests.Task.create(self.allocator, request, .{ .index = index, .generation = client.generation }, self.secret, self.wallTime()) catch |err| {
                    consume(client, request.consumed);
                    if (err == error.InvalidPath) client.keep_alive = false;
                    const status: u16 = if (err == error.Unauthorized) 401 else if (err == error.NotFound) 404 else if (err == error.InvalidPath) 400 else if (err == error.Validation) 422 else 503;
                    try self.respond(index, status, "{\"errors\":{\"body\":[\"invalid request\"]}}");
                    return;
                };
                consume(client, request.consumed);
                client.task = task;
                if (task.needs_hash) self.startHash(task) else self.queue(task);
            },
        }
    }

    fn consume(client: *Client, consumed: usize) void {
        const remaining = client.input.items.len - consumed;
        std.mem.copyForwards(u8, client.input.items[0..remaining], client.input.items[consumed..]);
        std.crypto.secureZero(u8, client.input.items[remaining..]);
        client.input.items.len = remaining;
    }

    fn queue(self: *Server, task: *requests.Task) void {
        const index = task.recipient.index;
        const client = &self.clients[index];
        client.state = .queued;
        self.sequence +%= 1;
        client.sequence = self.sequence;
        self.loop.watch(client.fd, self.token(index), false, false) catch self.closeClient(index);
    }

    fn startHash(self: *Server, task: *requests.Task) void {
        const index = task.recipient.index;
        self.clients[index].state = .hashing;
        self.loop.watch(self.clients[index].fd, self.token(index), false, false) catch {
            self.finish(task, 503, "{\"errors\":{\"body\":[\"worker unavailable\"]}}");
            return;
        };
        if (task.job.mode == .hash) self.io.randomSecure(&task.job.salt) catch {
            self.finish(task, 503, "{\"errors\":{\"body\":[\"random source unavailable\"]}}");
            return;
        };
        if (!self.pool.submit(&task.job)) self.finish(task, 503, "{\"errors\":{\"body\":[\"password queue full\"]}}");
    }

    fn finish(self: *Server, task: *requests.Task, status: u16, body: []const u8) void {
        defer task.destroy(self.allocator);
        if (!self.isLive(task)) return;
        const index = task.recipient.index;
        self.clients[index].task = null;
        self.respond(index, status, body) catch self.closeClient(index);
    }

    fn userResponse(self: *Server, task: *requests.Task) void {
        const body = task.userBody(self.secret, self.wallTime()) catch {
            self.finish(task, 503, "{\"errors\":{\"body\":[\"response unavailable\"]}}");
            return;
        };
        self.finish(task, if (task.route == .register) 201 else 200, body);
    }

    fn workerReady(self: *Server) void {
        var completed: [bcrypt.capacity]*bcrypt.Job = undefined;
        const count = self.pool.collect(&completed);
        for (completed[0..count]) |job| {
            const task: *requests.Task = @fieldParentPtr("job", job);
            if (!self.isLive(task)) {
                task.destroy(self.allocator);
            } else if (!job.ok) {
                self.finish(task, if (job.mode == .verify) 401 else 503, "{\"errors\":{\"body\":[\"password check failed\"]}}");
            } else if (job.mode == .verify) {
                self.userResponse(task);
            } else self.queue(task);
        }
    }

    fn readClient(self: *Server, index: usize) !void {
        const client = &self.clients[index];
        var buffer: [4096]u8 = undefined;
        for (0..8) |_| {
            const n = c.recv(client.fd, &buffer, buffer.len, 0);
            if (n == 0) {
                self.closeClient(index);
                return;
            }
            if (n < 0) {
                if (c.errno(n) == .INTR) continue;
                if (c.errno(n) == .AGAIN) return;
                self.closeClient(index);
                return;
            }
            const len: usize = @intCast(n);
            if (client.input.items.len + len > max_input) {
                client.keep_alive = false;
                try self.respond(index, 413, "{\"errors\":{\"body\":[\"request buffer limit\"]}}");
                return;
            }
            try client.input.appendSlice(self.allocator, buffer[0..len]);
            // A partial-request deadline is fixed at its first byte, not extended by trickles.
            if (client.input.items.len == len) client.last_activity = self.now();
            try self.processInput(index);
            if (client.state != .reading) return;
        }
    }

    fn writeClient(self: *Server, index: usize) !void {
        const client = &self.clients[index];
        const n = events.send(client.fd, client.output[client.sent..]);
        if (n < 0) {
            if (c.errno(n) == .AGAIN or c.errno(n) == .INTR) return;
            self.closeClient(index);
            return;
        }
        if (n == 0) {
            self.closeClient(index);
            return;
        }
        client.sent += @intCast(n);
        if (client.sent != client.output.len) return;
        self.allocator.free(client.output);
        client.output = &.{};
        if (!client.keep_alive) {
            self.closeClient(index);
            return;
        }
        client.state = .reading;
        client.last_activity = self.now();
        if (client.input.items.len == 0) {
            client.input.deinit(self.allocator);
            client.input = .empty;
        }
        try self.loop.watch(client.fd, self.token(index), true, false);
        if (client.input.items.len != 0) try self.processInput(index);
    }

    fn watchDatabase(self: *Server, index: usize, read: bool, write: bool) !void {
        const database = &self.databases[index];
        const conn = database.connection orelse if (database.opening) |opening| opening.conn else return;
        const fd = pg.PQsocket(conn);
        if (fd < 0) return error.DatabaseSocket;
        // libpq can change sockets during connection establishment. Old readiness
        // events must not advance a replacement connection or a reused descriptor.
        if (database.fd != fd) {
            database.fd = fd;
            database.generation +%= 1;
        }
        const tag = (@as(u64, database.generation) << 32) | database_bit | index;
        try self.loop.watch(fd, tag, read, write);
    }

    fn databaseFailed(self: *Server, index: usize) void {
        const database = &self.databases[index];
        if (database.connection) |connection| pg.PQfinish(connection);
        if (database.opening) |opening| pg.PQfinish(opening.conn);
        database.connection = null;
        database.opening = null;
        database.fd = -1;
        database.generation +%= 1;
        database.retry_at = self.now() + database.retry_delay;
        database.retry_delay = @min(database.retry_delay * 2, 5_000);
        if (database.active) |task| {
            database.active = null;
            // An uncertain write belongs to this failed connection, never the queue.
            self.finish(task, 503, "{\"errors\":{\"body\":[\"database unavailable\"]}}");
        }
    }

    fn maintainDatabases(self: *Server, current: i64) void {
        for (self.databases, 0..) |*database, index| {
            if ((database.active != null and current - database.active_since > 8_000) or
                (database.opening != null and current - database.active_since > 20_000))
            {
                self.databaseFailed(index);
            } else if (database.connection == null and database.opening == null and current >= database.retry_at) {
                database.opening = pg.Connector.start(self.database_url) catch {
                    self.databaseFailed(index);
                    continue;
                };
                database.active_since = current;
                self.watchDatabase(index, false, true) catch self.databaseFailed(index);
            }
        }
    }

    fn isLive(self: *Server, task: *requests.Task) bool {
        const client = self.clients[task.recipient.index];
        return (client.state == .queued or client.state == .database or client.state == .hashing) and
            client.generation == task.recipient.generation and client.task == task;
    }

    fn databaseReady(self: *Server, index: usize, readable: bool) !void {
        const database = &self.databases[index];
        if (database.opening) |*opening| {
            const interest = opening.advance(readable) catch {
                self.databaseFailed(index);
                return;
            };
            if (interest.ready) {
                database.connection = opening.conn;
                database.opening = null;
                database.retry_delay = 250;
                self.watchDatabase(index, true, false) catch self.databaseFailed(index);
            } else self.watchDatabase(index, interest.read, interest.write) catch self.databaseFailed(index);
            return;
        }
        const connection = database.connection orelse return;
        if (readable and pg.PQconsumeInput(connection) != 1) {
            self.databaseFailed(index);
            return;
        }
        const flush = pg.PQflush(connection);
        if (flush < 0) {
            self.databaseFailed(index);
            return;
        }
        self.watchDatabase(index, true, flush == 1) catch {
            self.databaseFailed(index);
            return;
        };
        while (database.active != null and pg.PQisBusy(connection) == 0) {
            const task = database.active.?;
            const result = pg.PQgetResult(connection) orelse {
                // The statement is fully drained, including its transaction completion.
                if (task.operation) |*operation| {
                    if ((operation.stage == .commit or operation.stage == .rollback) and pg.PQtransactionStatus(connection) != 0) {
                        self.databaseFailed(index);
                        return;
                    }
                    if (operation.stage == .rollback and task.status != 200) {
                        self.databaseFailed(index);
                        return;
                    }
                    if (operation.stage == .commit and task.status != 200) operation.transaction = false;
                    // Keep transaction ownership even when the HTTP recipient has gone away.
                    if (operation.advance(task.status)) {
                        task.status = 503;
                        database.active_since = self.now();
                        task.send(connection) catch {
                            self.databaseFailed(index);
                            return;
                        };
                        try self.databaseReady(index, false);
                        return;
                    }
                    task.status = if (operation.http_status >= 400) operation.http_status else 200;
                }
                if (self.isLive(task) and task.status == 200) {
                    if (task.read) |*read| {
                        if (read.family != .single and read.phase == .page) {
                            read.phase = .count;
                            task.status = 503;
                            database.active_since = self.now();
                            task.send(connection) catch {
                                self.databaseFailed(index);
                                return;
                            };
                            try self.databaseReady(index, false);
                            return;
                        }
                    }
                }
                database.active = null;
                if (!self.isLive(task)) {
                    task.destroy(self.allocator);
                } else if (task.status != 200) {
                    self.finish(task, task.status, "{\"errors\":{\"body\":[\"query failed\"]}}");
                } else if (task.operation) |operation| {
                    if (operation.http_status == 204) {
                        self.finish(task, 204, "");
                    } else {
                        const body = operation.json(task.arena.allocator()) catch {
                            self.finish(task, 503, "{\"errors\":{\"body\":[\"operation response unavailable\"]}}");
                            return;
                        };
                        self.finish(task, operation.http_status, body);
                    }
                } else if (task.read) |read| {
                    const body = read.json(task.arena.allocator()) catch {
                        self.finish(task, 503, "{\"errors\":{\"body\":[\"article response unavailable\"]}}");
                        return;
                    };
                    self.finish(task, 200, body);
                } else if (task.route == .tags or task.route.isProfile()) {
                    self.finish(task, 200, task.body.?);
                } else if (task.route == .login) {
                    const hash = task.row.?.hash orelse "";
                    if (hash.len != 60) {
                        self.finish(task, 503, "{\"errors\":{\"body\":[\"invalid stored hash\"]}}");
                    } else {
                        @memcpy(task.job.hash[0..60], hash);
                        self.startHash(task);
                    }
                } else self.userResponse(task);
                return;
            };
            defer pg.PQclear(result);
            task.status = pg.status(result);
            if (task.status != 200) continue;
            if (task.operation) |*operation| {
                task.status = pg.operationResult(result, operation, task.arena.allocator()) catch 503;
            } else if (task.read) |*read| {
                if (read.phase == .page) {
                    read.rows = pg.articlePage(result, task.arena.allocator(), read.family == .single) catch {
                        task.status = 503;
                        continue;
                    };
                    if (read.family == .single and read.rows.len == 0) task.status = 404;
                } else read.count = pg.articleCount(result) catch {
                    task.status = 503;
                    continue;
                };
            } else if (task.route == .tags) {
                task.body = pg.tagsJson(result, task.arena.allocator()) catch null;
                if (task.body == null) task.status = 503;
            } else if (task.route.isProfile()) {
                task.body = pg.profileJson(result, task.arena.allocator()) catch {
                    task.status = 503;
                    continue;
                };
                if (task.body == null) task.status = 404;
            } else {
                task.row = pg.user(result, task.arena.allocator(), task.route == .login) catch {
                    task.status = 503;
                    continue;
                };
                if (task.row == null) task.status = 401;
            }
        }
    }

    fn dispatch(self: *Server) !void {
        for (0..64) |_| {
            var oldest: ?usize = null;
            for (self.clients, 0..) |client, index| {
                if (client.state == .queued and (oldest == null or client.sequence < self.clients[oldest.?].sequence)) oldest = index;
            }
            const index = oldest orelse return;
            const task = self.clients[index].task.?;
            const slot = for (self.databases, 0..) |database, i| {
                if (database.connection != null and database.active == null) break i;
            } else {
                // Wait only for ready, occupied owners. An entirely unavailable
                // database fails unsent work promptly instead of hiding a backlog.
                for (self.databases) |database| if (database.connection != null) return;
                self.finish(task, 503, "{\"errors\":{\"body\":[\"database unavailable\"]}}");
                continue;
            };
            const database = &self.databases[slot];
            self.clients[index].state = .database;
            database.active = task;
            database.active_since = self.now();
            task.send(database.connection.?) catch {
                self.databaseFailed(slot);
                continue;
            };
            try self.databaseReady(slot, false);
        }
    }

    fn run(self: *Server) !void {
        try self.loop.watch(self.listener, listener_token, true, false);
        try self.loop.watch(self.pool.pipe[0], worker_token, true, false);
        for (0..self.databases.len) |index| try self.watchDatabase(index, true, false);
        var ready: [128]events.Event = undefined;
        while (true) {
            const count = try self.loop.wait(&ready);
            for (ready[0..count]) |event| {
                if (event.token == listener_token) {
                    try self.acceptClients();
                    continue;
                }
                if (event.token & database_bit != 0) {
                    const index: usize = @as(u32, @truncate(event.token)) & ~@as(u32, @intCast(database_bit));
                    if (index < self.databases.len and self.databases[index].generation == event.token >> 32) {
                        if (event.failed) self.databaseFailed(index) else try self.databaseReady(index, event.readable);
                    }
                    continue;
                }
                if (event.token == worker_token) {
                    self.workerReady();
                    continue;
                }
                const slot: u32 = @truncate(event.token);
                if (slot < 3) continue;
                const index: usize = slot - 3;
                if (index >= self.clients.len) continue;
                const client = &self.clients[index];
                if (client.state == .closed or client.generation != event.token >> 32) continue;
                if (event.failed) {
                    self.closeClient(index);
                    continue;
                }
                if (event.readable and client.state == .reading) self.readClient(index) catch self.closeClient(index);
                if (event.writable and client.state == .writing) self.writeClient(index) catch self.closeClient(index);
            }
            const current = self.now();
            for (self.clients, 0..) |client, index| {
                const limit: i64 = if (client.state == .reading and client.input.items.len == 0) 70_000 else 9_000;
                if (client.state != .closed and current - client.last_activity > limit) self.closeClient(index);
            }
            self.maintainDatabases(current);
            try self.dispatch();
        }
    }
};

fn listen(host: []const u8, port: u16) !c_int {
    var address: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    var parts = std.mem.splitScalar(u8, host, '.');
    var bytes: [4]u8 = undefined;
    for (&bytes) |*byte| byte.* = std.fmt.parseInt(u8, parts.next() orelse return error.InvalidHost, 10) catch return error.InvalidHost;
    if (parts.next() != null) return error.InvalidHost;
    address.addr = @bitCast(bytes);
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = c.close(fd);
    try events.nonblocking(fd);
    const one: c_int = 1;
    if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int)) < 0) return error.SocketOption;
    if (c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) < 0) return error.Bind;
    if (c.listen(fd, 256) < 0) return error.Listen;
    return fd;
}

pub fn main(init: std.process.Init) !void {
    const env = init.minimal.environ;
    const url = env.getPosix("DATABASE_URL") orelse return error.MissingDatabaseUrl;
    const secret = env.getPosix("JWT_SECRET") orelse return error.MissingJwtSecret;
    if (secret.len == 0) return error.EmptyJwtSecret;
    const host = env.getPosix("HOST") orelse "127.0.0.1";
    const port = try std.fmt.parseInt(u16, env.getPosix("PORT") orelse "3000", 10);
    const allocator = init.gpa;
    const clients = try allocator.alloc(Client, max_clients);
    defer allocator.free(clients);
    @memset(clients, .{});
    var pool: bcrypt.Pool = .{};
    try pool.start(init.io);
    defer {
        pool.stop();
        var completed: [bcrypt.capacity]*bcrypt.Job = undefined;
        const count = pool.collect(&completed);
        for (completed[0..count]) |job| {
            const task: *requests.Task = @fieldParentPtr("job", job);
            task.destroy(allocator);
        }
    }
    var databases: [database_connections]Database = @splat(.{});
    defer for (&databases) |*database| {
        if (database.connection) |connection| pg.PQfinish(connection);
        if (database.opening) |opening| pg.PQfinish(opening.conn);
        if (database.active) |task| task.destroy(allocator);
    };
    for (&databases) |*database| database.connection = try pg.connect(url, init.io);
    var loop = try events.Loop.init();
    defer loop.deinit();
    const listener = try listen(host, port);
    defer _ = c.close(listener);
    var server: Server = .{
        .allocator = allocator,
        .io = init.io,
        .loop = loop,
        .listener = listener,
        .databases = &databases,
        .database_url = url,
        .clients = clients,
        .pool = &pool,
        .secret = secret,
    };
    defer {
        for (0..clients.len) |index| server.closeClient(index);
    }
    std.log.info("all API routes on {s}:{d}; {d} database connections, two bcrypt workers, prepared API queries: {}", .{ host, port, database_connections, pg.prepared_queries });
    try server.run();
}

test {
    _ = http;
    _ = @import("auth.zig");
    _ = bcrypt;
    _ = @import("profiles.zig");
    _ = @import("url.zig");
    _ = @import("articles.zig");
}
