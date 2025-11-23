const std = @import("std");
const asar = @import("asar.zig");

const WalkContext = struct {
    allocator: std.mem.Allocator,
    source_dir: std.fs.Dir,
    entries: std.ArrayList(FileToWrite),
    unpack_patterns: []const []const u8,
    total_size: usize,

    const FileToWrite = struct {
        relative_path: []const u8,
        size: usize,
        should_unpack: bool,
    };
};

/// Pack a directory into an ASAR archive
pub fn pack(allocator: std.mem.Allocator, source_path: []const u8, output_path: []const u8, unpack_patterns: []const []const u8) !void {
    // Open source directory
    var source_dir = try std.fs.cwd().openDir(source_path, .{ .iterate = true });
    defer source_dir.close();

    // Walk directory and collect files
    var ctx = WalkContext{
        .allocator = allocator,
        .source_dir = source_dir,
        .entries = std.ArrayList(WalkContext.FileToWrite).init(allocator),
        .unpack_patterns = unpack_patterns,
        .total_size = 0,
    };
    defer {
        for (ctx.entries.items) |entry| {
            allocator.free(entry.relative_path);
        }
        ctx.entries.deinit();
    }

    try walkDirectory(&ctx, source_dir, "");

    // Build header JSON
    const header_json = try buildHeader(allocator, ctx.entries.items);
    defer allocator.free(header_json);

    // Calculate offsets
    const header_size = header_json.len;
    const header_end = 8 + header_size;
    const padding = asar.calculatePadding(header_end);

    // Create output file
    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    // Write header size
    var header_size_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &header_size_bytes, header_size, .little);
    try output_file.writeAll(&header_size_bytes);

    // Write header JSON
    try output_file.writeAll(header_json);

    // Write padding
    if (padding > 0) {
        const padding_bytes = [_]u8{0} ** 4;
        try output_file.writeAll(padding_bytes[0..padding]);
    }

    // Write file data
    for (ctx.entries.items) |entry| {
        if (entry.should_unpack) continue; // Skip unpacked files

        const file = try source_dir.openFile(entry.relative_path, .{});
        defer file.close();

        var buffer: [8192]u8 = undefined;
        while (true) {
            const n = try file.read(&buffer);
            if (n == 0) break;
            try output_file.writeAll(buffer[0..n]);
        }
    }

    // Copy unpacked files to .unpacked directory
    if (ctx.entries.items.len > 0) {
        var has_unpacked = false;
        for (ctx.entries.items) |entry| {
            if (entry.should_unpack) {
                has_unpacked = true;
                break;
            }
        }

        if (has_unpacked) {
            const unpacked_dir = try std.fmt.allocPrint(allocator, "{s}.unpacked", .{output_path});
            defer allocator.free(unpacked_dir);

            // Create unpacked directory
            std.fs.cwd().makeDir(unpacked_dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            var unpacked_root = try std.fs.cwd().openDir(unpacked_dir, .{});
            defer unpacked_root.close();

            for (ctx.entries.items) |entry| {
                if (!entry.should_unpack) continue;

                // Ensure parent directories exist
                if (std.fs.path.dirname(entry.relative_path)) |parent| {
                    try unpacked_root.makePath(parent);
                }

                // Copy file
                try source_dir.copyFile(entry.relative_path, unpacked_root, entry.relative_path, .{});
            }
        }
    }
}

fn walkDirectory(ctx: *WalkContext, dir: std.fs.Dir, prefix: []const u8) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = if (prefix.len == 0)
            try ctx.allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ prefix, entry.name });

        switch (entry.kind) {
            .file => {
                const stat = try dir.statFile(entry.name);
                const size = stat.size;
                const should_unpack = shouldUnpack(full_path, ctx.unpack_patterns);

                try ctx.entries.append(.{
                    .relative_path = full_path,
                    .size = size,
                    .should_unpack = should_unpack,
                });

                if (!should_unpack) {
                    ctx.total_size += size;
                }
            },
            .directory => {
                var subdir = try dir.openDir(entry.name, .{ .iterate = true });
                defer subdir.close();
                try walkDirectory(ctx, subdir, full_path);
                ctx.allocator.free(full_path);
            },
            else => {
                ctx.allocator.free(full_path);
            },
        }
    }
}

fn shouldUnpack(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (matchGlob(path, pattern)) return true;
    }
    return false;
}

fn matchGlob(path: []const u8, pattern: []const u8) bool {
    // Simple glob matching - supports * and ** wildcards
    if (std.mem.indexOf(u8, pattern, "**") != null) {
        // Recursive wildcard
        const parts = std.mem.split(u8, pattern, "**");
        // For now, just do simple suffix matching
        if (std.mem.endsWith(u8, path, parts.rest())) return true;
    } else if (std.mem.indexOf(u8, pattern, "*") != null) {
        // Simple wildcard - match extension
        if (std.mem.startsWith(u8, pattern, "*.")) {
            const ext = pattern[1..];
            return std.mem.endsWith(u8, path, ext);
        }
    } else {
        // Exact match
        return std.mem.eql(u8, path, pattern);
    }
    return false;
}

const TreeNode = struct {
    files: std.StringHashMap(TreeNode),
    size: ?usize = null,
    offset: ?usize = null,

    fn init(allocator: std.mem.Allocator) TreeNode {
        return .{
            .files = std.StringHashMap(TreeNode).init(allocator),
        };
    }

    fn deinit(self: *TreeNode, allocator: std.mem.Allocator) void {
        var it = self.files.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(allocator);
        }
        self.files.deinit();
    }

    fn toJson(self: *const TreeNode, writer: anytype, is_root: bool) !void {
        if (self.size) |size| {
            // Leaf node (file)
            try writer.print("{{\"size\":{d},\"offset\":\"{d}\"}}", .{ size, self.offset.? });
        } else {
            // Directory node
            if (!is_root) try writer.writeAll("{");
            try writer.writeAll("\"files\":{");

            var first = true;
            var it = self.files.iterator();
            while (it.next()) |kv| {
                if (!first) try writer.writeByte(',');
                first = false;

                try writer.print("\"{s}\":", .{kv.key_ptr.*});
                try kv.value_ptr.toJson(writer, false);
            }

            try writer.writeByte('}');
            if (!is_root) try writer.writeByte('}');
        }
    }
};

fn buildHeader(allocator: std.mem.Allocator, entries: []const WalkContext.FileToWrite) ![]u8 {
    var root = TreeNode.init(allocator);
    defer root.deinit(allocator);

    var current_offset: usize = 0;
    for (entries) |entry| {
        if (entry.should_unpack) continue;

        try addToTree(allocator, &root, entry.relative_path, entry.size, current_offset);
        current_offset += entry.size;
    }

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try buffer.append('{');
    try root.toJson(buffer.writer(), true);
    try buffer.append('}');

    return try buffer.toOwnedSlice();
}

fn addToTree(allocator: std.mem.Allocator, root: *TreeNode, path: []const u8, size: usize, offset: usize) !void {
    var current = root;
    var it = std.mem.splitScalar(u8, path, '/');

    var segments = std.ArrayList([]const u8).init(allocator);
    defer segments.deinit();

    while (it.next()) |segment| {
        try segments.append(segment);
    }

    for (segments.items, 0..) |segment, i| {
        const is_last = i == segments.items.len - 1;

        if (is_last) {
            // File entry
            var leaf = TreeNode.init(allocator);
            leaf.size = size;
            leaf.offset = offset;
            try current.files.put(try allocator.dupe(u8, segment), leaf);
        } else {
            // Directory entry
            if (current.files.getPtr(segment)) |existing| {
                current = existing;
            } else {
                const key = try allocator.dupe(u8, segment);
                try current.files.put(key, TreeNode.init(allocator));
                current = current.files.getPtr(segment).?;
            }
        }
    }
}

