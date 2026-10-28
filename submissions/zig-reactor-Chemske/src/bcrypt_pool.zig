const std = @import("std");
const c = std.c;
const events = @import("events.zig");
const lanes = @import("bcrypt_lanes.zig");
const batch_width = @import("build_options").bcrypt_lanes;
const gather_ms = @import("build_options").bcrypt_gather_ms;

pub const capacity = @import("build_options").bcrypt_jobs;
pub const worker_count = @import("build_options").bcrypt_workers;
pub const Job = struct {
    mode: enum { hash, verify } = .hash,
    password: [72]u8 = @splat(0),
    password_len: usize = 0,
    hash: [60:0]u8 = @splat(0),
    salt: [16]u8 = undefined,
    ok: bool = false,
};

const verify = lanes.verifyScalar;

pub const Pool = struct {
    io: std.Io = undefined,
    pipe: [2]c_int = .{ -1, -1 },
    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    threads: [worker_count]?std.Thread = @splat(null),
    pending: [capacity]*Job = undefined,
    pending_count: usize = 0,
    completed: [capacity]*Job = undefined,
    completed_count: usize = 0,
    outstanding: usize = 0,
    job_limit: usize = capacity,
    stopping: bool = false,
    gathering: bool = false,
    hash_batches: [4]u64 = @splat(0),

    pub const Stats = struct { outstanding: usize, batches: [4]u64 };

    pub fn stats(self: *Pool) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .outstanding = self.outstanding, .batches = self.hash_batches };
    }

    // The pool's address must remain stable after this call.
    pub fn start(self: *Pool, io: std.Io, workers: usize, jobs: usize) !void {
        std.debug.assert(workers > 0 and workers <= worker_count and jobs > 0 and jobs <= capacity);
        self.io = io;
        self.job_limit = jobs;
        if (c.pipe(&self.pipe) < 0) return error.CompletionPipe;
        errdefer self.stop();
        try events.nonblocking(self.pipe[0]);
        try events.nonblocking(self.pipe[1]);
        for (self.threads[0..workers]) |*thread| thread.* = try std.Thread.spawn(.{}, work, .{self});
    }

    pub fn stop(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.available.broadcast(self.io);
        self.mutex.unlock(self.io);
        for (self.threads) |thread| if (thread) |t| t.join();
        for (self.pipe) |fd| if (fd >= 0) {
            _ = c.close(fd);
        };
    }

    pub fn submit(self: *Pool, job: *Job) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or self.outstanding == self.job_limit) return false;
        self.pending[self.pending_count] = job;
        self.pending_count += 1;
        self.outstanding += 1;
        if (self.gathering) self.available.broadcast(self.io) else self.available.signal(self.io);
        return true;
    }

    pub fn collect(self: *Pool, output: *[capacity]*Job) usize {
        var bytes: [64]u8 = undefined;
        while (true) {
            const n = c.read(self.pipe[0], &bytes, bytes.len);
            if (n > 0) continue;
            if (n < 0 and c.errno(n) == .INTR) continue;
            break;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const count = self.completed_count;
        @memcpy(output[0..count], self.completed[0..count]);
        self.completed_count = 0;
        self.outstanding -= count;
        return count;
    }

    fn work(self: *Pool) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while ((self.pending_count == 0 or self.gathering) and !self.stopping) self.available.waitUncancelable(self.io, &self.mutex);
            if (self.pending_count == 0) {
                self.mutex.unlock(self.io);
                return;
            }
            if (gather_ms > 0 and self.pending_count < batch_width and !self.stopping) {
                self.gathering = true;
                const deadline = (std.Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(gather_ms), .clock = .awake } }).toDeadline(self.io);
                while (self.pending_count < batch_width and !self.stopping)
                    self.available.waitTimeout(self.io, &self.mutex, deadline) catch break;
                self.gathering = false;
            }
            // Shutdown can let another worker drain the pending queue while a
            // collector wakes. It never leaves an empty group in the CPU path.
            if (self.pending_count == 0) {
                self.mutex.unlock(self.io);
                continue;
            }
            const count = @min(self.pending_count, batch_width);
            var jobs: [4]*Job = undefined;
            @memcpy(jobs[0..count], self.pending[0..count]);
            self.pending_count -= count;
            std.mem.copyForwards(*Job, self.pending[0..self.pending_count], self.pending[count .. self.pending_count + count]);
            if (self.pending_count != 0) self.available.broadcast(self.io);
            self.mutex.unlock(self.io);
            const computed = lanes.process(Job, jobs[0..count]);
            for (jobs[0..count]) |job| std.crypto.secureZero(u8, &job.password);
            self.mutex.lockUncancelable(self.io);
            if (computed != 0) self.hash_batches[computed - 1] += 1;
            @memcpy(self.completed[self.completed_count .. self.completed_count + count], jobs[0..count]);
            self.completed_count += count;
            self.mutex.unlock(self.io);
            const byte = [_]u8{1};
            while (c.write(self.pipe[1], &byte, 1) < 0) {
                if (c.errno(@as(c_int, -1)) != .INTR) break;
            }
        }
    }
};

test "upstream Go bcrypt seed is verified without caching or skipping the work" {
    const seed: [60:0]u8 = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq".*;
    try std.testing.expect(verify(&seed, "password123"));
    try std.testing.expect(!verify(&seed, "wrong-password"));
    var invalid = seed;
    invalid[2] = 'x';
    try std.testing.expect(!verify(&invalid, "password123"));
}
