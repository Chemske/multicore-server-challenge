const std = @import("std");
const catalog = @import("query_catalog");

pub fn main() void {
    inline for (.{ catalog.articles.Family.feed, .all, .tag, .author, .favorited }) |family| {
        std.debug.print("BEGIN {s} page\n{s}\nEND\n", .{ @tagName(family), catalog.pages.statement(family, false) });
        std.debug.print("BEGIN {s} count\n{s}\nEND\n", .{ @tagName(family), catalog.pages.statement(family, true) });
    }
}
