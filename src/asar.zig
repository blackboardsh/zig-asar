const std = @import("std");

/// ASAR archive format:
/// [8 bytes: header size as u64 little-endian]
/// [N bytes: JSON header UTF-8]
/// [padding to 4-byte alignment]
/// [file data concatenated]
///
/// Header JSON structure:
/// {
///   "files": {
///     "path": {
///       "files": { ... }  // for directories
///     },
///     "file.txt": {
///       "size": 1234,
///       "offset": "0"     // offset is a string in Electron's ASAR
///     }
///   }
/// }

pub const FileEntry = struct {
    size: usize,
    offset: usize,
};

pub const DirEntry = struct {
    files: std.StringHashMap(Entry),

    pub fn deinit(self: *DirEntry, allocator: std.mem.Allocator) void {
        var it = self.files.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(allocator);
        }
        self.files.deinit();
    }
};

pub const Entry = union(enum) {
    file: FileEntry,
    dir: DirEntry,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .file => {},
            .dir => |*d| d.deinit(allocator),
        }
    }
};

pub const Header = struct {
    files: std.StringHashMap(Entry),

    pub fn deinit(self: *Header, allocator: std.mem.Allocator) void {
        var it = self.files.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            kv.value_ptr.deinit(allocator);
        }
        self.files.deinit();
    }
};

/// Parse ASAR header from JSON
pub fn parseHeader(allocator: std.mem.Allocator, json_str: []const u8) !Header {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const files_obj = root.get("files") orelse return error.InvalidHeader;

    var header = Header{
        .files = std.StringHashMap(Entry).init(allocator),
    };
    errdefer header.deinit(allocator);

    try parseEntries(allocator, &header.files, files_obj.object);
    return header;
}

fn parseEntries(allocator: std.mem.Allocator, map: *std.StringHashMap(Entry), obj: std.json.ObjectMap) !void {
    var it = obj.iterator();
    while (it.next()) |kv| {
        const name = try allocator.dupe(u8, kv.key_ptr.*);
        errdefer allocator.free(name);

        const value = kv.value_ptr.*;
        const entry_obj = value.object;

        if (entry_obj.get("files")) |files| {
            // Directory entry
            var dir = DirEntry{
                .files = std.StringHashMap(Entry).init(allocator),
            };
            errdefer dir.deinit(allocator);

            try parseEntries(allocator, &dir.files, files.object);
            try map.put(name, .{ .dir = dir });
        } else if (entry_obj.get("size")) |size_val| {
            // File entry
            const size = @as(usize, @intCast(size_val.integer));
            const offset_str = entry_obj.get("offset") orelse return error.InvalidHeader;
            const offset = try std.fmt.parseInt(usize, offset_str.string, 10);

            try map.put(name, .{ .file = .{ .size = size, .offset = offset } });
        }
    }
}

/// Find a file entry by path
pub fn findEntry(header: *const Header, path: []const u8) ?FileEntry {
    var current_map = &header.files;
    var it = std.mem.splitScalar(u8, path, '/');

    while (it.next()) |segment| {
        const entry = current_map.get(segment) orelse return null;

        // If this is the last segment, it should be a file
        if (it.rest().len == 0) {
            return switch (entry) {
                .file => |f| f,
                .dir => null,
            };
        }

        // Otherwise, it should be a directory
        switch (entry) {
            .file => return null,
            .dir => |*d| current_map = &d.files,
        }
    }

    return null;
}

/// Calculate padding needed for 4-byte alignment
pub fn calculatePadding(offset: usize) usize {
    const remainder = offset % 4;
    return if (remainder == 0) 0 else 4 - remainder;
}

test "parseHeader and findEntry" {
    const testing = std.testing;
    const json =
        \\{"files":{"a.txt":{"size":5,"offset":"0"},"dir":{"files":{"b.txt":{"size":3,"offset":"5"}}}}}
    ;

    var header = try parseHeader(testing.allocator, json);
    defer header.deinit(testing.allocator);

    const a = findEntry(&header, "a.txt").?;
    try testing.expectEqual(@as(usize, 5), a.size);
    try testing.expectEqual(@as(usize, 0), a.offset);

    const b = findEntry(&header, "dir/b.txt").?;
    try testing.expectEqual(@as(usize, 3), b.size);
    try testing.expectEqual(@as(usize, 5), b.offset);

    // Missing entries and type mismatches
    try testing.expect(findEntry(&header, "missing.txt") == null);
    try testing.expect(findEntry(&header, "dir") == null); // directory, not a file
    try testing.expect(findEntry(&header, "a.txt/nope") == null); // file used as directory
    try testing.expect(findEntry(&header, "dir/missing.txt") == null);
}

test "parseHeader rejects invalid header" {
    const testing = std.testing;
    try testing.expectError(error.InvalidHeader, parseHeader(testing.allocator, "{}"));
}

test "calculatePadding aligns to 4 bytes" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), calculatePadding(0));
    try testing.expectEqual(@as(usize, 3), calculatePadding(1));
    try testing.expectEqual(@as(usize, 2), calculatePadding(2));
    try testing.expectEqual(@as(usize, 1), calculatePadding(3));
    try testing.expectEqual(@as(usize, 0), calculatePadding(4));
}
