const std = @import("std");
const articles = @import("articles.zig");
const batch = @import("read_batch.zig");

pub const Input = struct { viewer: []const u8, limit: []const u8, offset: []const u8, key: []const u8 };
const requested = "WITH requested AS MATERIALIZED (SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(viewer,lim,off,key,ordinal)), ";

pub fn name(family: articles.Family, count: bool) [:0]const u8 {
    return switch (family) {
        .single => unreachable,
        inline else => |f| if (count) "batch_count_" ++ @tagName(f) else "batch_page_" ++ @tagName(f),
    };
}

fn ids(comptime family: articles.Family) []const u8 {
    const bare = switch (family) {
        .all => "SELECT p.id FROM articles p ORDER BY p.id DESC LIMIT 100 OFFSET k.off",
        .tag => "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id=(SELECT id FROM tags WHERE name=k.key) ORDER BY at.article_id DESC LIMIT 100 OFFSET k.off",
        .author => "SELECT p.id FROM articles p WHERE p.author_id=(SELECT id FROM users WHERE username=k.key) ORDER BY p.id DESC LIMIT 100 OFFSET k.off",
        .favorited => "SELECT f.article_id AS id FROM favorites f WHERE f.user_id=(SELECT id FROM users WHERE username=k.key) ORDER BY f.article_id DESC LIMIT 100 OFFSET k.off",
        .feed => articles.feedIds("k.key::bigint", "k.lim", "k.off", "100"),
        .single => unreachable,
    };
    // The constant inner bound also gives generic plans a realistic page size.
    return "SELECT id FROM (" ++ bare ++ ") capped LIMIT k.lim";
}

fn pageSql(comptime family: articles.Family) [:0]const u8 {
    return comptime requested ++
        "keys AS (SELECT DISTINCT key,lim,off FROM requested), " ++
        "pages AS MATERIALIZED (SELECT k.key,k.lim,k.off,a.id,a.author_id,a.slug,a.title,a.description, " ++
        "to_char(a.created_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS created_at, " ++
        "to_char(a.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS updated_at, " ++
        "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) AS name FROM article_tags at WHERE at.article_id=a.id ORDER BY name) AS tags, " ++
        "(SELECT count(*) FROM favorites f WHERE f.article_id=a.id) AS favorites,u.username,u.bio,u.image " ++
        "FROM keys k CROSS JOIN LATERAL (" ++ ids(family) ++ ") p JOIN articles a ON a.id=p.id JOIN users u ON u.id=a.author_id), " ++
        "page_ids AS (SELECT key,lim,off,array_agg(id) AS ids,array_agg(DISTINCT author_id) AS authors FROM pages GROUP BY key,lim,off), " ++
        "flags AS MATERIALIZED (SELECT r.ordinal, " ++
        "ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id=r.viewer AND f.article_id=ANY(p.ids)) AS fav, " ++
        "ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id=r.viewer AND fo.followee_id=ANY(p.authors)) AS fol " ++
        "FROM requested r LEFT JOIN page_ids p ON p.key=r.key AND p.lim=r.lim AND p.off=r.off) " ++
        "SELECT r.ordinal,p.slug,p.title,p.description,p.created_at,p.updated_at,p.tags,p.favorites,p.id=ANY(f.fav),p.username,p.bio,p.image,p.author_id=ANY(f.fol) " ++
        "FROM requested r JOIN flags f ON f.ordinal=r.ordinal LEFT JOIN pages p ON p.key=r.key AND p.lim=r.lim AND p.off=r.off ORDER BY r.ordinal,p.id DESC";
}

fn countSql(comptime family: articles.Family) [:0]const u8 {
    const counted = switch (family) {
        .all => "SELECT count(*) FROM (SELECT 1 FROM articles LIMIT 1000) s",
        .tag => "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id=(SELECT id FROM tags WHERE name=k.key) LIMIT 1000) s",
        .author => "SELECT count(*) FROM (SELECT 1 FROM articles WHERE author_id=(SELECT id FROM users WHERE username=k.key) LIMIT 1000) s",
        .favorited => "SELECT count(*) FROM (SELECT 1 FROM favorites WHERE user_id=(SELECT id FROM users WHERE username=k.key) LIMIT 1000) s",
        .feed => "SELECT count(*) FROM (SELECT 1 FROM articles WHERE author_id IN (SELECT followee_id FROM follows WHERE follower_id=k.key::bigint) LIMIT 1000) s",
        .single => unreachable,
    };
    return comptime requested ++ "keys AS (SELECT DISTINCT key FROM requested), totals AS MATERIALIZED (SELECT k.key,(" ++ counted ++ ") AS n FROM keys k) SELECT r.ordinal,t.n FROM requested r JOIN totals t ON t.key=r.key ORDER BY r.ordinal";
}

pub fn statement(family: articles.Family, count: bool) [:0]const u8 {
    return switch (family) {
        .single => unreachable,
        inline else => |f| if (count) countSql(f) else pageSql(f),
    };
}

fn numbers(allocator: std.mem.Allocator, inputs: []const Input, comptime field: []const u8) ![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '{');
    for (inputs, 0..) |input, index| {
        const number = @field(input, field);
        if (number.len == 0) return error.BatchParameter;
        for (number) |ch| if (ch < '0' or ch > '9') return error.BatchParameter;
        if (index != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, number);
    }
    try out.append(allocator, '}');
    return allocator.dupeSentinel(u8, out.items, 0);
}

pub fn parameters(allocator: std.mem.Allocator, inputs: []const Input) ![4][:0]const u8 {
    if (inputs.len == 0 or inputs.len > batch.capacity) return error.BatchSize;
    var keys: [batch.capacity]batch.Input = undefined;
    var size: usize = 0;
    for (inputs, 0..) |input, index| {
        size += input.viewer.len + input.limit.len + input.offset.len + input.key.len;
        if (size > batch.max_parameter_bytes) return error.BatchSize;
        keys[index] = .{ .viewer = input.viewer, .slug = input.key };
    }
    const text = try batch.parameters(allocator, keys[0..inputs.len]);
    errdefer for (text) |value| allocator.free(value);
    const limits = try numbers(allocator, inputs, "limit");
    errdefer allocator.free(limits);
    const offsets = try numbers(allocator, inputs, "offset");
    return .{ text[0], limits, offsets, text[1] };
}

test "page batch parameters preserve each viewer, window and filter" {
    const a = std.testing.allocator;
    const values = try parameters(a, &.{ .{ .viewer = "1", .limit = "10", .offset = "0", .key = "a,\"b" }, .{ .viewer = "0", .limit = "0", .offset = "9223372036854775807", .key = "" } });
    defer for (values) |value| a.free(value);
    try std.testing.expectEqualStrings("{1,0}", values[0]);
    try std.testing.expectEqualStrings("{10,0}", values[1]);
    try std.testing.expectEqualStrings("{0,9223372036854775807}", values[2]);
    try std.testing.expectEqualStrings("{\"a,\\\"b\",\"\"}", values[3]);
    try std.testing.expectError(error.BatchParameter, parameters(a, &.{.{ .viewer = "1", .limit = "-1", .offset = "0", .key = "x" }}));
}
