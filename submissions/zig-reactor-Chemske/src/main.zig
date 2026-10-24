const std = @import("std");
const c = std.c;
const events = @import("events.zig");
const http = @import("http.zig");
const pg = @import("postgres.zig");

const max_clients = 256;
const max_input = 32 * 1024;
const database_token = 0;
const listener_token = 1;
const State = enum { closed, reading, queued, writing };
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
};
const Recipient = struct { index: usize, generation: u32 };

const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: events.Loop,
    listener: c_int,
    database: ?*pg.Conn,
    clients: []Client,
    sequence: u64 = 0,
    active: ?Recipient = null,
    active_since: i64 = 0,
    result_body: ?[]u8 = null,
    result_ok: bool = false,

    fn now(self: *Server) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn token(self: *Server, index: usize) u64 {
        return (@as(u64, self.clients[index].generation) << 32) | (index + 2);
    }

    fn closeClient(self: *Server, index: usize) void {
        const client = &self.clients[index];
        if (client.fd < 0) return;
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
            400 => "Bad Request",
            404 => "Not Found",
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
                const remaining = client.input.items.len - request.consumed;
                std.mem.copyForwards(u8, client.input.items[0..remaining], client.input.items[request.consumed..]);
                client.input.items.len = remaining;
                if (!request.tags) {
                    try self.respond(index, 404, "{\"errors\":{\"body\":[\"route not implemented\"]}}");
                    return;
                }
                client.state = .queued;
                self.sequence +%= 1;
                client.sequence = self.sequence;
                client.last_activity = self.now();
                try self.loop.watch(client.fd, self.token(index), false, false);
            },
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
                try self.respond(index, 431, "{\"errors\":{\"body\":[\"request buffer limit\"]}}");
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

    fn databaseFailed(self: *Server) !void {
        if (self.database) |connection| pg.PQfinish(connection);
        self.database = null;
        if (self.result_body) |body| self.allocator.free(body);
        self.result_body = null;
        if (self.active) |recipient| {
            self.active = null;
            if (self.isLive(recipient)) try self.respond(recipient.index, 503, "{\"errors\":{\"body\":[\"database unavailable\"]}}");
        }
    }

    fn isLive(self: *Server, recipient: Recipient) bool {
        const client = self.clients[recipient.index];
        return client.state == .queued and client.generation == recipient.generation;
    }

    fn databaseReady(self: *Server, readable: bool) !void {
        const connection = self.database orelse return;
        if (readable and pg.PQconsumeInput(connection) != 1) {
            try self.databaseFailed();
            return;
        }
        const flush = pg.PQflush(connection);
        if (flush < 0) {
            try self.databaseFailed();
            return;
        }
        try self.loop.watch(pg.PQsocket(connection), database_token, true, flush == 1);
        while (self.active != null and pg.PQisBusy(connection) == 0) {
            const result = pg.PQgetResult(connection) orelse {
                const recipient = self.active.?;
                self.active = null;
                if (self.isLive(recipient)) {
                    try self.respond(recipient.index, if (self.result_ok) 200 else 503, self.result_body orelse "{\"errors\":{\"body\":[\"database query failed\"]}}");
                }
                if (self.result_body) |body| self.allocator.free(body);
                self.result_body = null;
                return;
            };
            defer pg.PQclear(result);
            self.result_body = pg.tagsJson(result, self.allocator) catch null;
            self.result_ok = self.result_body != null;
        }
    }

    fn dispatch(self: *Server) !void {
        if (self.active != null) return;
        var oldest: ?usize = null;
        for (self.clients, 0..) |client, index| {
            if (client.state == .queued and (oldest == null or client.sequence < self.clients[oldest.?].sequence)) oldest = index;
        }
        const index = oldest orelse return;
        const connection = self.database orelse {
            try self.respond(index, 503, "{\"errors\":{\"body\":[\"database unavailable\"]}}");
            return;
        };
        self.active = .{ .index = index, .generation = self.clients[index].generation };
        self.active_since = self.now();
        self.result_ok = false;
        pg.queryTags(connection) catch {
            try self.databaseFailed();
            return;
        };
        try self.databaseReady(false);
    }

    fn run(self: *Server) !void {
        try self.loop.watch(self.listener, listener_token, true, false);
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
                    if (event.failed) try self.databaseFailed() else try self.databaseReady(event.readable);
                    continue;
                }
                const index: usize = @as(u32, @truncate(event.token)) - 2;
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
            if (self.active != null and current - self.active_since > 8_000) try self.databaseFailed();
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
    var server: Server = .{
        .allocator = allocator,
        .io = init.io,
        .loop = try events.Loop.init(),
        .listener = try listen(host, port),
        .database = try pg.connect(url, init.io),
        .clients = clients,
    };
    defer server.loop.deinit();
    defer _ = c.close(server.listener);
    defer if (server.database) |connection| pg.PQfinish(connection);
    defer for (0..clients.len) |index| server.closeClient(index);
    std.log.info("milestone 1: GET /api/tags on {s}:{d}; one database connection, 256 client slots", .{ host, port });
    try server.run();
}

test {
    _ = http;
}
