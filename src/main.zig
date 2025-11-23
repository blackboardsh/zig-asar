const std = @import("std");
const reader = @import("reader.zig");
const writer = @import("writer.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "pack")) {
        try commandPack(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "list")) {
        try commandList(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "extract")) {
        try commandExtract(allocator, args[2..]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
        std.process.exit(1);
    }
}

fn printUsage() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\zig-asar - ASAR archive tool
        \\
        \\Usage:
        \\  zig-asar pack <source_dir> <output.asar> [--unpack <pattern>...]
        \\      Pack a directory into an ASAR archive
        \\
        \\  zig-asar list <archive.asar>
        \\      List files in an ASAR archive
        \\
        \\  zig-asar extract <archive.asar> <file_path>
        \\      Extract a single file from an ASAR archive
        \\
        \\Options:
        \\  --unpack <pattern>  Glob pattern for files to keep unpacked
        \\                      Can be specified multiple times
        \\                      Examples: *.node, *.dll, bin/**
        \\
        \\Examples:
        \\  zig-asar pack myapp app.asar
        \\  zig-asar pack myapp app.asar --unpack *.node --unpack *.dll
        \\  zig-asar list app.asar
        \\  zig-asar extract app.asar views/index.html
        \\
    );
}

fn commandPack(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Error: pack requires <source_dir> and <output.asar>\n", .{});
        try printUsage();
        std.process.exit(1);
    }

    const source_path = args[0];
    const output_path = args[1];

    // Parse --unpack patterns
    var patterns = std.ArrayList([]const u8).init(allocator);
    defer patterns.deinit();

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--unpack")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --unpack requires a pattern argument\n", .{});
                std.process.exit(1);
            }
            try patterns.append(args[i]);
        } else {
            std.debug.print("Error: unknown option: {s}\n", .{args[i]});
            std.process.exit(1);
        }
    }

    std.debug.print("Packing {s} -> {s}\n", .{ source_path, output_path });
    if (patterns.items.len > 0) {
        std.debug.print("Unpack patterns: {s}\n", .{patterns.items});
    }

    try writer.pack(allocator, source_path, output_path, patterns.items);
    std.debug.print("✓ Successfully created {s}\n", .{output_path});
}

fn commandList(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: list requires <archive.asar>\n", .{});
        try printUsage();
        std.process.exit(1);
    }

    const archive_path = args[0];
    var archive = try reader.AsarArchive.open(allocator, archive_path);
    defer archive.close();

    const stdout = std.io.getStdOut().writer();
    try archive.listFiles(stdout);
}

fn commandExtract(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Error: extract requires <archive.asar> and <file_path>\n", .{});
        try printUsage();
        std.process.exit(1);
    }

    const archive_path = args[0];
    const file_path = args[1];

    var archive = try reader.AsarArchive.open(allocator, archive_path);
    defer archive.close();

    const data = try archive.readFile(file_path);
    defer allocator.free(data);

    const stdout = std.io.getStdOut();
    try stdout.writeAll(data);
}
