const std = @import("std");
const c = std.c;

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

pub fn queryTags(conn: *Conn) !void {
    if (PQsendQueryParams(conn, "SELECT name FROM tags ORDER BY name", 0, null, null, null, null, 0) != 1) return error.DatabaseQuery;
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
