// Parallel schedule adapted from Zig 0.17.0's std/crypto/bcrypt.zig (MIT).
// Copyright (c) Zig contributors. See vendor/zig-LICENSE.
const std = @import("std");
const bcrypt = std.crypto.pwhash.bcrypt;
const State = bcrypt.State;

fn word(bytes: []const u8, position: *usize) u32 {
    var value: u32 = 0;
    inline for (0..4) |_| {
        if (position.* == bytes.len) position.* = 0;
        value = (value << 8) | bytes[position.*];
        position.* += 1;
    }
    return value;
}

inline fn half(state: *const State, current: u32, other: u32, comptime round: usize) u32 {
    var value = state.sboxes[0][@as(u8, @truncate(other >> 24))];
    value +%= state.sboxes[1][@as(u8, @truncate(other >> 16))];
    value ^= state.sboxes[2][@as(u8, @truncate(other >> 8))];
    value +%= state.sboxes[3][@as(u8, @truncate(other))];
    return current ^ value ^ state.subkeys[round];
}

// Independent hashes expose instruction-level parallelism between dependent
// Blowfish lookups. Every lane keeps its own salt, state and complete rounds.
inline fn encipher(comptime width: usize, states: *const [width]State, left: *[width]u32, right: *[width]u32) void {
    var l = left.*;
    var r = right.*;
    inline for (0..width) |lane| l[lane] ^= states[lane].subkeys[0];
    inline for (1..17) |round| {
        inline for (0..width) |lane| {
            if (round % 2 == 1) r[lane] = half(&states[lane], r[lane], l[lane], round) else l[lane] = half(&states[lane], l[lane], r[lane], round);
        }
    }
    inline for (0..width) |lane| {
        left[lane] = r[lane] ^ states[lane].subkeys[17];
        right[lane] = l[lane];
    }
}

inline fn mixSalt(comptime width: usize, salts: *const [width][4]u32, position: *usize, left: *[width]u32, right: *[width]u32) void {
    inline for (0..width) |lane| {
        left[lane] ^= salts[lane][position.*];
        right[lane] ^= salts[lane][position.* + 1];
    }
    position.* = (position.* + 2) & 3;
}

fn expand(comptime width: usize, comptime salted: bool, states: *[width]State, keys: *const [width][18]u32, salts: *const [width][4]u32) void {
    for (0..18) |index| {
        inline for (0..width) |lane| states[lane].subkeys[index] ^= keys[lane][index];
    }
    var left: [width]u32 = @splat(0);
    var right: [width]u32 = @splat(0);
    var position: usize = 0;
    for (0..9) |pair| {
        if (salted) mixSalt(width, salts, &position, &left, &right);
        encipher(width, states, &left, &right);
        inline for (0..width) |lane| {
            states[lane].subkeys[pair * 2] = left[lane];
            states[lane].subkeys[pair * 2 + 1] = right[lane];
        }
    }
    for (0..4) |box| {
        for (0..128) |pair| {
            if (salted) mixSalt(width, salts, &position, &left, &right);
            encipher(width, states, &left, &right);
            inline for (0..width) |lane| {
                states[lane].sboxes[box][pair * 2] = left[lane];
                states[lane].sboxes[box][pair * 2 + 1] = right[lane];
            }
        }
    }
}

pub fn derive(comptime width: usize, passwords: [width][]const u8, salts: [width][16]u8, comptime cost: u6) [width][23]u8 {
    if (width < 1 or width > 4) @compileError("bcrypt width must be 1-4");
    if (cost < 4 or cost > 31) @compileError("bcrypt cost must be 4-31");
    var states: [width]State = @splat(.{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&states));
    var password_bytes: [width][73]u8 = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&password_bytes));
    var password_words: [width][18]u32 = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&password_words));
    var salt_words: [width][4]u32 = undefined;
    var repeated_salt: [width][18]u32 = undefined;
    inline for (0..width) |lane| {
        const length = @min(passwords[lane].len, 72);
        @memcpy(password_bytes[lane][0..length], passwords[lane][0..length]);
        password_bytes[lane][length] = 0;
        var position: usize = 0;
        for (&password_words[lane]) |*value| value.* = word(password_bytes[lane][0 .. length + 1], &position);
        for (&salt_words[lane], 0..) |*value, index| value.* = std.mem.readInt(u32, salts[lane][index * 4 ..][0..4], .big);
        for (&repeated_salt[lane], 0..) |*value, index| value.* = salt_words[lane][index % 4];
    }
    expand(width, true, &states, &password_words, &salt_words);
    for (0..(@as(u64, 1) << cost)) |_| {
        expand(width, false, &states, &password_words, &salt_words);
        expand(width, false, &states, &repeated_salt, &salt_words);
    }
    var text: [width][6]u32 = @splat(.{ 0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274 });
    for (0..64) |_| {
        for (0..3) |pair| {
            var left: [width]u32 = undefined;
            var right: [width]u32 = undefined;
            inline for (0..width) |lane| {
                left[lane] = text[lane][pair * 2];
                right[lane] = text[lane][pair * 2 + 1];
            }
            encipher(width, &states, &left, &right);
            inline for (0..width) |lane| {
                text[lane][pair * 2] = left[lane];
                text[lane][pair * 2 + 1] = right[lane];
            }
        }
    }
    var result: [width][23]u8 = undefined;
    inline for (0..width) |lane| {
        var bytes: [24]u8 = undefined;
        for (text[lane], 0..) |value, index| std.mem.writeInt(u32, bytes[index * 4 ..][0..4], value, .big);
        result[lane] = bytes[0..23].*;
    }
    return result;
}

test "independent bcrypt lanes match standard-library output for byte and length boundaries" {
    const long: [80]u8 = @splat(0xe9);
    const inputs = [_][]const u8{ "", "a", "password123", "pässword ☕", long[0..71], long[0..72], &long };
    inline for (1..5) |width| {
        for (inputs, 0..) |_, index| {
            var passwords: [width][]const u8 = undefined;
            var salts: [width][16]u8 = undefined;
            inline for (0..width) |lane| {
                passwords[lane] = inputs[(index + lane) % inputs.len];
                for (&salts[lane], 0..) |*byte, salt_index| byte.* = @truncate(index * 31 + lane * 47 + salt_index * 13);
            }
            const actual = derive(width, passwords, salts, 4);
            inline for (0..width) |lane| {
                const expected = bcrypt.bcrypt(passwords[lane], &salts[lane], .{ .rounds_log = 4, .silently_truncate_password = true });
                try std.testing.expectEqualSlices(u8, &expected, &actual[lane]);
            }
        }
    }
}

test "four distinct lanes retain every cost-ten round" {
    const passwords = [4][]const u8{ "password123", "different password", "non-ascii é", "" };
    var salts: [4][16]u8 = undefined;
    for (&salts, 0..) |*salt, lane| {
        for (salt, 0..) |*byte, index| byte.* = @truncate(lane * 53 + index * 19);
    }
    const actual = derive(4, passwords, salts, 10);
    for (passwords, salts, actual) |password, salt, digest| {
        const expected = bcrypt.bcrypt(password, &salt, .{ .rounds_log = 10, .silently_truncate_password = true });
        try std.testing.expectEqualSlices(u8, &expected, &digest);
    }
}
