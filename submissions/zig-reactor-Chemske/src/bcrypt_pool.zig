const std = @import("std");
const c = std.c;
const events = @import("events.zig");
const lanes = @import("bcrypt_lanes.zig");
const batch_width = @import("build_options").bcrypt_lanes;
const gather_ms = @import("build_options").bcrypt_gather_ms;

pub const capacity = @import("build_options").bcrypt_jobs;
pub const worker_count = @import("build_options").bcrypt_workers;
pub const Job = struct {
    owner: usize = 0,
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
    other_pipes: [3][2]c_int = @splat(.{ -1, -1 }),
    owner_count: usize = 1,
    owner_outstanding: [4]usize = @splat(0),
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
        return self.statsFor(0);
    }

    pub fn statsFor(self: *Pool, owner: usize) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .outstanding = self.owner_outstanding[owner], .batches = self.hash_batches };
    }

    // The pool's address must remain stable after this call.
    pub fn start(self: *Pool, io: std.Io, workers: usize, jobs: usize) !void {
        return self.startShared(io, workers, jobs, 1);
    }

    pub fn startShared(self: *Pool, io: std.Io, workers: usize, jobs: usize, owners: usize) !void {
        std.debug.assert(workers > 0 and workers <= worker_count and jobs > 0 and jobs <= capacity);
        std.debug.assert(owners > 0 and owners <= 4 and jobs >= owners);
        self.io = io;
        self.job_limit = jobs;
        self.owner_count = owners;
        if (c.pipe(&self.pipe) < 0) return error.CompletionPipe;
        errdefer self.stop();
        try events.nonblocking(self.pipe[0]);
        try events.nonblocking(self.pipe[1]);
        for (self.other_pipes[0 .. owners - 1]) |*fds| {
            if (c.pipe(fds) < 0) return error.CompletionPipe;
            try events.nonblocking(fds[0]);
            try events.nonblocking(fds[1]);
        }
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
        for (self.other_pipes) |fds| for (fds) |fd| {
            if (fd >= 0) _ = c.close(fd);
        };
    }

    pub fn readPipe(self: *const Pool, owner: usize) c_int {
        return if (owner == 0) self.pipe[0] else self.other_pipes[owner - 1][0];
    }

    fn writePipe(self: *const Pool, owner: usize) c_int {
        return if (owner == 0) self.pipe[1] else self.other_pipes[owner - 1][1];
    }

    pub fn submit(self: *Pool, job: *Job) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping or job.owner >= self.owner_count or self.outstanding == self.job_limit) return false;
        const quota = self.job_limit / self.owner_count + @intFromBool(job.owner < self.job_limit % self.owner_count);
        if (self.owner_outstanding[job.owner] == quota) return false;
        self.pending[self.pending_count] = job;
        self.pending_count += 1;
        self.outstanding += 1;
        self.owner_outstanding[job.owner] += 1;
        if (self.gathering) self.available.broadcast(self.io) else self.available.signal(self.io);
        return true;
    }

    pub fn collect(self: *Pool, output: *[capacity]*Job) usize {
        return self.collectOwner(0, output);
    }

    pub fn collectOwner(self: *Pool, owner: usize, output: *[capacity]*Job) usize {
        var bytes: [64]u8 = undefined;
        while (true) {
            const n = c.read(self.readPipe(owner), &bytes, bytes.len);
            if (n > 0) continue;
            if (n < 0 and c.errno(n) == .INTR) continue;
            break;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        var retained: usize = 0;
        for (self.completed[0..self.completed_count]) |job| {
            if (job.owner == owner) {
                output[count] = job;
                count += 1;
            } else {
                self.completed[retained] = job;
                retained += 1;
            }
        }
        self.completed_count = retained;
        self.outstanding -= count;
        self.owner_outstanding[owner] -= count;
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
            // A recipient may free its job as soon as completion is published.
            var notified: u8 = 0;
            for (jobs[0..count]) |job| notified |= @as(u8, 1) << @intCast(job.owner);
            self.mutex.lockUncancelable(self.io);
            if (computed != 0) self.hash_batches[computed - 1] += 1;
            @memcpy(self.completed[self.completed_count .. self.completed_count + count], jobs[0..count]);
            self.completed_count += count;
            self.mutex.unlock(self.io);
            const byte = [_]u8{1};
            for (0..self.owner_count) |owner| {
                if (notified & (@as(u8, 1) << @intCast(owner)) == 0) continue;
                while (c.write(self.writePipe(owner), &byte, 1) < 0) {
                    if (c.errno(@as(c_int, -1)) != .INTR) break;
                }
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

test "shared password execution preserves owner quotas and separate completion notifications" {
    var pool: Pool = .{};
    try pool.startShared(std.testing.io, 1, 4, 2);
    defer pool.stop();
    var jobs: [4]Job = @splat(.{ .mode = .verify });
    for (&jobs, 0..) |*job, index| {
        job.owner = index % 2;
        try std.testing.expect(pool.submit(job));
    }
    var excess: Job = .{ .mode = .verify };
    try std.testing.expect(!pool.submit(&excess));
    var counts: [2]usize = .{ 0, 0 };
    while (counts[0] + counts[1] != jobs.len) {
        var fds = [_]c.pollfd{
            .{ .fd = pool.readPipe(0), .events = c.POLL.IN, .revents = 0 },
            .{ .fd = pool.readPipe(1), .events = c.POLL.IN, .revents = 0 },
        };
        try std.testing.expect(c.poll(&fds, fds.len, 5000) > 0);
        for (fds, 0..) |fd, owner| {
            if (fd.revents & c.POLL.IN == 0) continue;
            var completed: [capacity]*Job = undefined;
            const count = pool.collectOwner(owner, &completed);
            for (completed[0..count]) |job| {
                try std.testing.expectEqual(owner, job.owner);
                try std.testing.expect(!job.ok);
            }
            counts[owner] += count;
        }
    }
    try std.testing.expectEqual([2]usize{ 2, 2 }, counts);
    try std.testing.expectEqual(@as(usize, 0), pool.statsFor(0).outstanding);
    try std.testing.expectEqual(@as(usize, 0), pool.statsFor(1).outstanding);
}
