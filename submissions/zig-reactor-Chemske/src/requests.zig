const std = @import("std");
const http = @import("http.zig");
const auth = @import("auth.zig");
const pg = @import("postgres.zig");
const bcrypt = @import("bcrypt_pool.zig");
const profiles = @import("profiles.zig");

pub const Recipient = struct { index: usize, generation: u32 };
pub const Task = struct {
    arena: std.heap.ArenaAllocator,
    recipient: Recipient,
    route: http.Route,
    params: [6]?[:0]const u8 = @splat(null),
    param_count: usize = 0,
    token: []const u8 = "",
    job: bcrypt.Job = .{},
    needs_hash: bool = false,
    row: ?pg.User = null,
    status: u16 = 503,
    body: ?[]const u8 = null,

    pub fn create(allocator: std.mem.Allocator, request: http.Request, recipient: Recipient, secret: []const u8, now: i64) !*Task {
        const self = try allocator.create(Task);
        self.* = .{ .arena = .init(allocator), .recipient = recipient, .route = request.route };
        errdefer self.destroy(allocator);
        const a = self.arena.allocator();
        const policy = request.route.auth();
        if (policy == .required or (policy == .optional and request.authorization != null)) {
            const identity = auth.verify(a, secret, request.authorization, now) catch return error.Unauthorized;
            if (request.route == .current or request.route == .update) self.token = try a.dupe(u8, identity.token);
            self.params[0] = try std.fmt.allocPrintSentinel(a, "{d}", .{identity.id}, 0);
        } else if (policy == .optional) self.params[0] = "0";
        if (request.route.isProfile()) {
            self.params[1] = try profiles.username(a, request.argument);
            self.param_count = 2;
            return self;
        }
        if (request.route == .tags) return self;
        if (request.route == .current) {
            self.param_count = 1;
            return self;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, a, request.body, .{ .allocate = .alloc_always }) catch return error.Validation;
        if (parsed.value != .object) return error.Validation;
        const wrapper = parsed.value.object.get("user") orelse return error.Validation;
        if (wrapper != .object) return error.Validation;
        const object = wrapper.object;
        switch (request.route) {
            .register => {
                self.params[0] = try text(a, object, "username", true, false);
                self.params[1] = try text(a, object, "email", true, false);
                try self.password(object, true);
                self.params[2] = &self.job.hash;
                self.param_count = 3;
            },
            .login => {
                self.params[0] = try text(a, object, "email", true, false);
                try self.password(object, true);
                self.needs_hash = false;
                self.job.mode = .verify;
                self.param_count = 1;
            },
            .update => {
                self.params[1] = try text(a, object, "email", false, false);
                self.params[2] = try text(a, object, "username", false, false);
                try self.password(object, false);
                self.params[3] = if (self.needs_hash) &self.job.hash else null;
                self.params[4] = try text(a, object, "bio", false, true);
                self.params[5] = try text(a, object, "image", false, true);
                self.param_count = 6;
            },
            else => unreachable,
        }
        return self;
    }

    fn text(a: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, required: bool, allow_empty: bool) !?[:0]const u8 {
        const value = object.get(key) orelse return if (required) error.Validation else null;
        if (value == .null and !required) return null;
        if (value != .string or (!allow_empty and value.string.len == 0)) return error.Validation;
        // Text parameters cannot carry NUL in PostgreSQL's text protocol.
        if (std.mem.indexOfScalar(u8, value.string, 0) != null) return error.Validation;
        return try a.dupeSentinel(u8, value.string, 0);
    }

    fn password(self: *Task, object: std.json.ObjectMap, required: bool) !void {
        const value = object.get("password") orelse return if (required) error.Validation else {};
        if (value == .null and !required) return;
        if (value != .string or value.string.len == 0) return error.Validation;
        if (self.route != .login and value.string.len > 72) return error.Validation;
        // Match Go bcrypt: reject long new passwords, truncate verification inputs.
        self.job.password_len = @min(value.string.len, self.job.password.len);
        @memcpy(self.job.password[0..self.job.password_len], value.string[0..self.job.password_len]);
        std.crypto.secureZero(u8, @constCast(value.string));
        self.needs_hash = true;
    }

    pub fn userBody(self: *Task, secret: []const u8, now: i64) ![]const u8 {
        const row = self.row.?;
        const a = self.arena.allocator();
        const token = if (self.route == .register or self.route == .login) try auth.issue(a, secret, row.id, now) else self.token;
        return std.json.Stringify.valueAlloc(a, .{ .user = .{
            .email = row.email,
            .token = token,
            .username = row.username,
            .bio = row.bio,
            .image = row.image,
        } }, .{});
    }

    pub fn destroy(self: *Task, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, &self.job.password);
        self.arena.deinit();
        allocator.destroy(self);
    }
};
