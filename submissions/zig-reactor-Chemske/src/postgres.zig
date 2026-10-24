const std = @import("std");
const c = std.c;
const http = @import("http.zig");

// Minimal declarations from PostgreSQL 18's public libpq-fe.h ABI.
pub const Conn = opaque {};
pub const Result = opaque {};
extern "c" fn PQconnectStart([*:0]const u8) ?*Conn;
extern "c" fn PQconnectPoll(*Conn) c_int;
pub extern "c" fn PQsocket(*const Conn) c_int;
extern "c" fn PQsetnonblocking(*Conn, c_int) c_int;
pub extern "c" fn PQfinish(*Conn) void;
extern "c" fn PQsendQueryParams(*Conn, [*:0]const u8, c_int, ?[*]const u32, ?[*]const ?[*:0]const u8, ?[*]const c_int, ?[*]const c_int, c_int) c_int;
pub extern "c" fn PQflush(*Conn) c_int;
pub extern "c" fn PQconsumeInput(*Conn) c_int;
pub extern "c" fn PQisBusy(*Conn) c_int;
pub extern "c" fn PQgetResult(*Conn) ?*Result;
pub extern "c" fn PQclear(*Result) void;
extern "c" fn PQresultStatus(*const Result) c_int;
extern "c" fn PQntuples(*const Result) c_int;
extern "c" fn PQnfields(*const Result) c_int;
extern "c" fn PQgetisnull(*const Result, c_int, c_int) c_int;
extern "c" fn PQgetvalue(*const Result, c_int, c_int) [*]const u8;
extern "c" fn PQgetlength(*const Result, c_int, c_int) c_int;
extern "c" fn PQresultErrorField(*const Result, c_int) ?[*:0]const u8;

pub fn connect(url: [*:0]const u8, io: std.Io) !*Conn {
    const conn = PQconnectStart(url) orelse return error.DatabaseConnect;
    errdefer PQfinish(conn);
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 20_000;
    while (std.Io.Clock.awake.now(io).toMilliseconds() < deadline) {
        const state = PQconnectPoll(conn);
        if (state == 0) return error.DatabaseConnect;
        if (state == 3) {
            if (PQsetnonblocking(conn, 1) != 0) return error.DatabaseNonblocking;
            return conn;
        }
        const fd = PQsocket(conn);
        if (fd < 0) return error.DatabaseConnect;
        var fds = [_]c.pollfd{.{ .fd = fd, .events = if (state == 1) c.POLL.IN else c.POLL.OUT, .revents = 0 }};
        if (c.poll(&fds, 1, 100) < 0 and c.errno(@as(c_int, -1)) != .INTR) return error.DatabasePoll;
    }
    return error.DatabaseConnectTimeout;
}

pub fn query(conn: *Conn, route: http.Route, params: []const ?[:0]const u8) !void {
    const statement: [*:0]const u8 = switch (route) {
        .tags => "SELECT name FROM tags ORDER BY name",
        .register => "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
        .login => "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
        .current => "SELECT id, username, email, bio, image FROM users WHERE id = $1",
        .update => "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING id, username, email, bio, image",
        .unknown => unreachable,
    };
    var values: [6]?[*:0]const u8 = @splat(null);
    for (params, 0..) |param, i| values[i] = if (param) |p| p.ptr else null;
    // libpq copies the parameter bytes before this call returns.
    if (PQsendQueryParams(conn, statement, @intCast(params.len), null, &values, null, null, 0) != 1) return error.DatabaseQuery;
}

pub fn status(result: *Result) u16 {
    if (PQresultStatus(result) == 2) return 200;
    const code = PQresultErrorField(result, 'C') orelse return 503;
    return if (std.mem.eql(u8, std.mem.span(code), "23505")) 422 else 503;
}

pub const User = struct {
    id: []const u8,
    username: []const u8,
    email: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
    hash: ?[]const u8,
};

fn field(result: *Result, column: c_int, allocator: std.mem.Allocator) !?[]const u8 {
    if (PQgetisnull(result, 0, column) != 0) return null;
    const len: usize = @intCast(PQgetlength(result, 0, column));
    if (len > 1024 * 1024) return error.ResponseTooLarge;
    return try allocator.dupe(u8, PQgetvalue(result, 0, column)[0..len]);
}

pub fn user(result: *Result, allocator: std.mem.Allocator, login: bool) !?User {
    if (PQresultStatus(result) != 2 or PQnfields(result) != @as(c_int, if (login) 6 else 5)) return error.DatabaseResult;
    if (PQntuples(result) == 0) return null;
    if (PQntuples(result) != 1) return error.DatabaseResult;
    return .{
        .id = (try field(result, 0, allocator)) orelse return error.DatabaseResult,
        .username = (try field(result, 1, allocator)) orelse return error.DatabaseResult,
        .email = (try field(result, 2, allocator)) orelse return error.DatabaseResult,
        .bio = try field(result, 3, allocator),
        .image = try field(result, 4, allocator),
        .hash = if (login) try field(result, 5, allocator) else null,
    };
}

pub fn tagsJson(result: *Result, allocator: std.mem.Allocator) ![]u8 {
    if (PQresultStatus(result) != 2 or PQnfields(result) != 1) return error.DatabaseResult;
    const count: usize = @intCast(PQntuples(result));
    const names = try allocator.alloc([]const u8, count);
    defer allocator.free(names);
    var total: usize = 0;
    for (names, 0..) |*name, index| {
        const row: c_int = @intCast(index);
        if (PQgetisnull(result, row, 0) != 0) return error.DatabaseResult;
        const len: usize = @intCast(PQgetlength(result, row, 0));
        total += len;
        if (total > 1024 * 1024) return error.ResponseTooLarge;
        name.* = PQgetvalue(result, row, 0)[0..len];
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .tags = names }, .{});
}
