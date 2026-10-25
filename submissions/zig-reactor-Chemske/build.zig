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
    const options = b.addOptions();
    options.addOption(bool, "prepared_queries", b.option(bool, "prepared-queries", "Prepare API queries per database connection") orelse true);
    const database_connections = b.option(usize, "db-connections", "Maximum owned PostgreSQL connections (1-95)") orelse 4;
    if (database_connections == 0 or database_connections > 95) @panic("db-connections must be between 1 and 95");
    options.addOption(usize, "database_connections", database_connections);
    module.addOptions("build_options", options);
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
