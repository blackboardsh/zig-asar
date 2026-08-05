const std = @import("std");
const reader = @import("reader.zig");
const writer = @import("writer.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        try printUsage(io);
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "pack")) {
        try commandPack(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "list")) {
        try commandList(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, command, "extract")) {
        try commandExtract(allocator, io, args[2..]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage(io);
        std.process.exit(1);
    }
}

fn printUsage(io: std.Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
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
    try stdout.flush();
}

fn commandPack(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    if (args.len < 2) {
        std.debug.print("Error: pack requires <source_dir> and <output.asar>\n", .{});
        try printUsage(io);
        std.process.exit(1);
    }

    const source_path = args[0];
    const output_path = args[1];

    // Parse --unpack patterns
    var patterns: std.ArrayList([]const u8) = .empty;
    defer patterns.deinit(allocator);

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--unpack")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --unpack requires a pattern argument\n", .{});
                std.process.exit(1);
            }
            try patterns.append(allocator, args[i]);
        } else {
            std.debug.print("Error: unknown option: {s}\n", .{args[i]});
            std.process.exit(1);
        }
    }

    std.debug.print("Packing {s} -> {s}\n", .{ source_path, output_path });
    if (patterns.items.len > 0) {
        std.debug.print("Unpack patterns:", .{});
        for (patterns.items) |pattern| {
            std.debug.print(" {s}", .{pattern});
        }
        std.debug.print("\n", .{});
    }

    try writer.pack(allocator, io, source_path, output_path, patterns.items);
    std.debug.print("✓ Successfully created {s}\n", .{output_path});
}

fn commandList(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: list requires <archive.asar>\n", .{});
        try printUsage(io);
        std.process.exit(1);
    }

    const archive_path = args[0];
    var archive = try reader.AsarArchive.open(allocator, io, archive_path);
    defer archive.close();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try archive.listFiles(stdout);
    try stdout.flush();
}

fn commandExtract(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    if (args.len < 2) {
        std.debug.print("Error: extract requires <archive.asar> and <file_path>\n", .{});
        try printUsage(io);
        std.process.exit(1);
    }

    const archive_path = args[0];
    const file_path = args[1];

    var archive = try reader.AsarArchive.open(allocator, io, archive_path);
    defer archive.close();

    const data = try archive.readFile(file_path);
    defer allocator.free(data);

    try std.Io.File.stdout().writeStreamingAll(io, data);
}
