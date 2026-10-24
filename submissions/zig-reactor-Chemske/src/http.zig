const std = @import("std");

const Header = extern struct { name: ?[*]const u8, name_len: usize, value: [*]const u8, value_len: usize };
extern "c" fn phr_parse_request([*]const u8, usize, *?[*]const u8, *usize, *?[*]const u8, *usize, *c_int, [*]Header, *usize, usize) c_int;

pub const max_head = 16 * 1024;
pub const Request = struct { consumed: usize, tags: bool, keep_alive: bool };
pub const Parse = union(enum) { more, bad: u16, request: Request };

pub fn parse(bytes: []const u8) Parse {
    var method: ?[*]const u8 = null;
    var path: ?[*]const u8 = null;
    var method_len: usize = 0;
    var path_len: usize = 0;
    var minor: c_int = 0;
    var headers: [64]Header = undefined;
    var count: usize = headers.len;
    const n = phr_parse_request(bytes.ptr, bytes.len, &method, &method_len, &path, &path_len, &minor, &headers, &count, 0);
    if (n == -2) return if (bytes.len >= max_head) .{ .bad = 431 } else .more;
    if (n < 0) return .{ .bad = 400 };
    if (n > max_head) return .{ .bad = 431 };
    if (minor != 1) return .{ .bad = 505 };
    var close = false;
    var host = false;
    var length: ?usize = null;
    for (headers[0..count]) |h| {
        const name = (h.name orelse return .{ .bad = 400 })[0..h.name_len];
        const value = std.mem.trim(u8, h.value[0..h.value_len], " \t");
        if (std.ascii.eqlIgnoreCase(name, "host")) {
            if (host or value.len == 0) return .{ .bad = 400 };
            host = true;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (value.len == 0) return .{ .bad = 400 };
            for (value) |ch| if (ch < '0' or ch > '9') return .{ .bad = 400 };
            const parsed = std.fmt.parseInt(usize, value, 10) catch return .{ .bad = 400 };
            if (length != null and length.? != parsed) return .{ .bad = 400 };
            length = parsed;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            // This milestone has no request-body routes. Reject and close before reuse.
            return .{ .bad = 400 };
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            var tokens = std.mem.splitScalar(u8, value, ',');
            while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), "close")) {
                close = true;
            };
        }
    }
    if (!host or (length orelse 0) != 0) return .{ .bad = 400 };
    const target = path.?[0..path_len];
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return .{ .request = .{
        .consumed = @intCast(n),
        .tags = std.mem.eql(u8, method.?[0..method_len], "GET") and std.mem.eql(u8, target[0..path_end], "/api/tags"),
        .keep_alive = !close,
    } };
}

test "partial headers, close dominance and conflicting framing" {
    try std.testing.expect(parse("GET /api/tags HTTP/1.1\r\nHost: x\r\n") == .more);
    const request = parse("GET /api/tags HTTP/1.1\r\nHost: x\r\nConnection: close, keep-alive\r\n\r\n").request;
    try std.testing.expect(request.tags and !request.keep_alive);
    try std.testing.expect(parse("GET /api/tags HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n") == .bad);
    try std.testing.expect(parse("GET /api/tags HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n") == .bad);
}

test "tags ignores auth, preserves the next pipelined request" {
    const first = "GET /api/tags?x=y HTTP/1.1\r\nHost: x\r\nAuthorization: \r\n\r\n";
    const result = parse(first ++ "GET / HTTP/1.1\r\nHost: x\r\n\r\n").request;
    try std.testing.expect(result.tags and result.keep_alive);
    try std.testing.expectEqual(first.len, result.consumed);
}
