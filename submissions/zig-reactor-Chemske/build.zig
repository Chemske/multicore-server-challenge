const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pg_root = b.option([]const u8, "pg-root", "PostgreSQL installation prefix");
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addCSourceFile(.{ .file = b.path("vendor/picohttpparser/picohttpparser.c"), .flags = &.{"-std=c99"} });
    module.linkSystemLibrary("pq", .{ .use_pkg_config = .no });
    if (pg_root) |prefix| {
        const lib = b.pathJoin(&.{ prefix, "lib" });
        module.addLibraryPath(.{ .cwd_relative = lib });
        module.addRPath(.{ .cwd_relative = lib });
    }
    const exe = b.addExecutable(.{ .name = "conduit", .root_module = module });
    b.installArtifact(exe);
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run protocol and configuration checks").dependOn(&run_tests.step);
}
