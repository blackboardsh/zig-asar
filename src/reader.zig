const std = @import("std");
const asar = @import("asar.zig");

pub const AsarArchive = struct {
    file: std.fs.File,
    header: asar.Header,
    data_offset: u64,
    allocator: std.mem.Allocator,

    /// Open an ASAR archive for reading
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*AsarArchive {
        const file = try std.fs.cwd().openFile(path, .{});
        errdefer file.close();

        // Read header size (8 bytes, little-endian u64)
        var header_size_bytes: [8]u8 = undefined;
        const n = try file.read(&header_size_bytes);
        if (n != 8) return error.InvalidArchive;

        const header_size = std.mem.readInt(u64, &header_size_bytes, .little);
        if (header_size > 100 * 1024 * 1024) return error.HeaderTooLarge; // 100MB sanity check

        // Read header JSON
        const header_json = try allocator.alloc(u8, header_size);
        defer allocator.free(header_json);

        const header_read = try file.read(header_json);
        if (header_read != header_size) return error.InvalidArchive;

        // Parse header
        var header = try asar.parseHeader(allocator, header_json);
        errdefer header.deinit(allocator);

        // Calculate data offset (header size + padding)
        const header_end = 8 + header_size;
        const padding = asar.calculatePadding(header_end);
        const data_offset = header_end + padding;

        // Create archive object
        const archive = try allocator.create(AsarArchive);
        archive.* = .{
            .file = file,
            .header = header,
            .data_offset = data_offset,
            .allocator = allocator,
        };

        return archive;
    }

    /// Close the archive and free resources
    pub fn close(self: *AsarArchive) void {
        self.header.deinit(self.allocator);
        self.file.close();
        self.allocator.destroy(self);
    }

    /// Read a file from the archive
    /// Caller owns the returned memory and must free it with allocator.free()
    pub fn readFile(self: *AsarArchive, path: []const u8) ![]u8 {
        const entry = asar.findEntry(&self.header, path) orelse return error.FileNotFound;

        // Seek to file position
        const file_offset = self.data_offset + entry.offset;
        try self.file.seekTo(file_offset);

        // Read file data
        const buffer = try self.allocator.alloc(u8, entry.size);
        errdefer self.allocator.free(buffer);

        const n = try self.file.read(buffer);
        if (n != entry.size) {
            self.allocator.free(buffer);
            return error.UnexpectedEOF;
        }

        return buffer;
    }

    /// List all files in the archive (for debugging/CLI)
    pub fn listFiles(self: *AsarArchive, writer: anytype) !void {
        try self.listFilesRecursive(writer, &self.header.files, "");
    }

    fn listFilesRecursive(self: *AsarArchive, writer: anytype, map: *const std.StringHashMap(asar.Entry), prefix: []const u8) !void {
        var it = map.iterator();
        while (it.next()) |kv| {
            const full_path = if (prefix.len == 0)
                kv.key_ptr.*
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, kv.key_ptr.* });
            defer if (prefix.len > 0) self.allocator.free(full_path);

            switch (kv.value_ptr.*) {
                .file => |f| {
                    try writer.print("{s} ({d} bytes)\n", .{ full_path, f.size });
                },
                .dir => |*d| {
                    try self.listFilesRecursive(writer, &d.files, full_path);
                },
            }
        }
    }
};

test "open and read simple archive" {
    // This is a placeholder - we'll need actual test archives
    // For now, just ensure compilation works
    _ = AsarArchive;
}
