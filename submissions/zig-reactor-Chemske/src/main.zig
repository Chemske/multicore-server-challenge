const std = @import("std");
const c = std.c;
const events = @import("events.zig");
const http = @import("http.zig");
const pg = @import("postgres.zig");
const requests = @import("requests.zig");
const bcrypt = @import("bcrypt_pool.zig");

const max_clients = 256;
const max_input = http.max_head + http.max_body + 4096;
const database_token = 0;
const listener_token = 1;
const worker_token = 2;
const State = enum { closed, reading, queued, hashing, writing };
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
    database: ?*pg.Conn,
    clients: []Client,
    pool: *bcrypt.Pool,
    secret: []const u8,
    sequence: u64 = 0,
    active: ?*requests.Task = null,
    active_since: i64 = 0,

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
            if (client.state == .queued and self.active != task) task.destroy(self.allocator);
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
            404 => "Not Found",
            413 => "Content Too Large",
            422 => "Unprocessable Content",
            431 => "Request Header Fields Too Large",
            505 => "HTTP Version Not Supported",
            else => "Service Unavailable",
        };
        client.output = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n{s}", .{ status, reason, body.len, if (client.keep_alive) @as([]const u8, "keep-alive") else "close", body });
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
                    const status: u16 = if (err == error.Unauthorized) 401 else if (err == error.InvalidPath) 400 else if (err == error.Validation) 422 else 503;
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

    fn databaseFailed(self: *Server) void {
        if (self.database) |connection| pg.PQfinish(connection);
        self.database = null;
        if (self.active) |task| {
            self.active = null;
            // A lost write may have committed. Never replay it automatically.
            self.finish(task, 503, "{\"errors\":{\"body\":[\"database unavailable\"]}}");
        }
    }

    fn isLive(self: *Server, task: *requests.Task) bool {
        const client = self.clients[task.recipient.index];
        return (client.state == .queued or client.state == .hashing) and
            client.generation == task.recipient.generation and client.task == task;
    }

    fn databaseReady(self: *Server, readable: bool) !void {
        const connection = self.database orelse return;
        if (readable and pg.PQconsumeInput(connection) != 1) {
            self.databaseFailed();
            return;
        }
        const flush = pg.PQflush(connection);
        if (flush < 0) {
            self.databaseFailed();
            return;
        }
        try self.loop.watch(pg.PQsocket(connection), database_token, true, flush == 1);
        while (self.active != null and pg.PQisBusy(connection) == 0) {
            const task = self.active.?;
            const result = pg.PQgetResult(connection) orelse {
                // The statement is fully drained, including its transaction completion.
                if (self.isLive(task) and task.status == 200) {
                    if (task.read) |*read| {
                        if (read.family != .single and read.phase == .page) {
                            read.phase = .count;
                            task.status = 503;
                            self.active_since = self.now();
                            pg.query(connection, task.route, task.params[0..task.param_count], task.read) catch {
                                self.databaseFailed();
                                return;
                            };
                            try self.databaseReady(false);
                            return;
                        }
                    }
                }
                self.active = null;
                if (!self.isLive(task)) {
                    task.destroy(self.allocator);
                } else if (task.status != 200) {
                    self.finish(task, task.status, "{\"errors\":{\"body\":[\"query failed\"]}}");
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
            if (task.read) |*read| {
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
        if (self.active != null) return;
        var oldest: ?usize = null;
        for (self.clients, 0..) |client, index| {
            if (client.state == .queued and (oldest == null or client.sequence < self.clients[oldest.?].sequence)) oldest = index;
        }
        const index = oldest orelse return;
        const task = self.clients[index].task.?;
        const connection = self.database orelse {
            self.finish(task, 503, "{\"errors\":{\"body\":[\"database unavailable\"]}}");
            return;
        };
        self.active = task;
        self.active_since = self.now();
        pg.query(connection, task.route, task.params[0..task.param_count], task.read) catch {
            self.databaseFailed();
            return;
        };
        try self.databaseReady(false);
    }

    fn run(self: *Server) !void {
        try self.loop.watch(self.listener, listener_token, true, false);
        try self.loop.watch(self.pool.pipe[0], worker_token, true, false);
        try self.loop.watch(pg.PQsocket(self.database.?), database_token, true, false);
        var ready: [128]events.Event = undefined;
        while (true) {
            const count = try self.loop.wait(&ready);
            for (ready[0..count]) |event| {
                if (event.token == listener_token) {
                    try self.acceptClients();
                    continue;
                }
                if (event.token == database_token) {
                    if (event.failed) self.databaseFailed() else try self.databaseReady(event.readable);
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
            if (self.active != null and current - self.active_since > 8_000) self.databaseFailed();
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
    var server: Server = .{
        .allocator = allocator,
        .io = init.io,
        .loop = try events.Loop.init(),
        .listener = try listen(host, port),
        .database = try pg.connect(url, init.io),
        .clients = clients,
        .pool = &pool,
        .secret = secret,
    };
    defer server.loop.deinit();
    defer _ = c.close(server.listener);
    defer if (server.database) |connection| pg.PQfinish(connection);
    defer {
        for (0..clients.len) |index| server.closeClient(index);
        if (server.active) |task| task.destroy(allocator);
    }
    std.log.info("milestone 4: article/feed reads, tags, users and profiles on {s}:{d}; one database connection, two bcrypt workers", .{ host, port });
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
