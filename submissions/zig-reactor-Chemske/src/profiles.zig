const std = @import("std");

pub const get_sql =
    \\SELECT u.id, u.username, u.bio, u.image,
    \\       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
    \\  FROM users u WHERE u.username = $2
;

pub const follow_sql =
    \\WITH target AS MATERIALIZED (
    \\    SELECT id, username, bio, image FROM users WHERE username = $2
    \\), changed AS (
    \\    INSERT INTO follows (follower_id, followee_id)
    \\    SELECT $1::bigint, id FROM target ON CONFLICT DO NOTHING
    \\    RETURNING followee_id
    \\)
    \\SELECT t.id, t.username, t.bio, t.image, true AS following
    \\  FROM target t CROSS JOIN (SELECT count(*) FROM changed) applied
;

pub const unfollow_sql =
    \\WITH target AS MATERIALIZED (
    \\    SELECT id, username, bio, image FROM users WHERE username = $2
    \\), changed AS (
    \\    DELETE FROM follows fo USING target t
    \\     WHERE fo.follower_id = $1::bigint AND fo.followee_id = t.id
    \\    RETURNING fo.followee_id
    \\)
    \\SELECT t.id, t.username, t.bio, t.image, false AS following
    \\  FROM target t CROSS JOIN (SELECT count(*) FROM changed) applied
;

pub const Profile = struct { username: []const u8, bio: ?[]const u8, image: ?[]const u8, following: bool };

pub fn username(allocator: std.mem.Allocator, encoded: []const u8) ![:0]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const byte = if (encoded[i] == '%') blk: {
            if (encoded.len - i < 3) return error.InvalidPath;
            const high = std.fmt.charToDigit(encoded[i + 1], 16) catch return error.InvalidPath;
            const low = std.fmt.charToDigit(encoded[i + 2], 16) catch return error.InvalidPath;
            i += 2;
            break :blk high * 16 + low;
        } else encoded[i];
        if (byte == 0) return error.Validation;
        try decoded.append(allocator, byte);
    }
    if (decoded.items.len == 0 or !std.unicode.utf8ValidateSlice(decoded.items)) return error.Validation;
    return allocator.dupeSentinel(u8, decoded.items, 0);
}

test "username path decoding is single-pass, preserves plus and validates text" {
    const a = std.testing.allocator;
    const decoded = try username(a, "a+%20%2F%C3%A9%252F");
    defer a.free(decoded);
    try std.testing.expectEqualStrings("a+ /é%2F", decoded);
    try std.testing.expectError(error.InvalidPath, username(a, "bad%2"));
    try std.testing.expectError(error.InvalidPath, username(a, "bad%GG"));
    try std.testing.expectError(error.Validation, username(a, "bad%00"));
    try std.testing.expectError(error.Validation, username(a, "%FF"));
}
