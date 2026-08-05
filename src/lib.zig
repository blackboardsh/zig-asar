const std = @import("std");
const asar = @import("asar.zig");
const reader = @import("reader.zig");
const writer = @import("writer.zig");

// Use a global allocator for the C API
// In production, we use the debug allocator for safety
var gpa: std.heap.DebugAllocator(.{}) = .init;
const allocator = gpa.allocator();

// Blocking single-threaded Io implementation for the C API: all file
// operations run synchronously on the calling thread.
var threaded: std.Io.Threaded = .init_single_threaded;

fn getIo() std.Io {
    return threaded.io();
}

// ============================================================================
// C API - Reading
// ============================================================================

/// Opaque type for C API
pub const AsarArchive = reader.AsarArchive;

/// Open an ASAR archive
/// Returns null on failure
/// Caller must call asar_close() when done
export fn asar_open(path: [*:0]const u8) ?*AsarArchive {
    const path_slice = std.mem.span(path);
    return reader.AsarArchive.open(allocator, getIo(), path_slice) catch |err| {
        std.debug.print("asar_open failed: {}\n", .{err});
        return null;
    };
}

/// Close an archive and free resources
export fn asar_close(archive: *AsarArchive) void {
    archive.close();
}

/// Read a file from the archive
/// Returns pointer to allocated buffer, or null on failure
/// size_out is set to the file size
/// Caller must call asar_free_buffer() to free the returned pointer
export fn asar_read_file(archive: *AsarArchive, path: [*:0]const u8, size_out: *usize) ?[*]const u8 {
    const path_slice = std.mem.span(path);
    const data = archive.readFile(path_slice) catch |err| {
        std.debug.print("asar_read_file failed for '{s}': {}\n", .{ path_slice, err });
        return null;
    };

    size_out.* = data.len;
    return data.ptr;
}

/// Free a buffer returned by asar_read_file
export fn asar_free_buffer(buffer: [*]const u8, size: usize) void {
    const slice = buffer[0..size];
    allocator.free(slice);
}

// ============================================================================
// C API - Writing
// ============================================================================

/// Pack a directory into an ASAR archive
/// unpack_patterns is an array of C strings (null-terminated patterns)
/// pattern_count is the number of patterns
/// Returns 1 on success, 0 on failure
export fn asar_pack(
    source_path: [*:0]const u8,
    output_path: [*:0]const u8,
    unpack_patterns: ?[*]const [*:0]const u8,
    pattern_count: c_int,
) c_int {
    const source_slice = std.mem.span(source_path);
    const output_slice = std.mem.span(output_path);

    // Convert C string array to Zig slices
    var patterns: std.ArrayList([]const u8) = .empty;
    defer {
        for (patterns.items) |pattern| {
            allocator.free(pattern);
        }
        patterns.deinit(allocator);
    }

    if (unpack_patterns) |patterns_ptr| {
        var i: usize = 0;
        while (i < pattern_count) : (i += 1) {
            const pattern_cstr = patterns_ptr[i];
            const pattern_slice = std.mem.span(pattern_cstr);
            const owned_pattern = allocator.dupe(u8, pattern_slice) catch return 0;
            patterns.append(allocator, owned_pattern) catch return 0;
        }
    }

    writer.pack(allocator, getIo(), source_slice, output_slice, patterns.items) catch |err| {
        std.debug.print("asar_pack failed: {}\n", .{err});
        return 0;
    };

    return 1;
}

// ============================================================================
// Tests
// ============================================================================

test "basic pack and read" {
    const testing = std.testing;
    const test_allocator = testing.allocator;
    const io = testing.io;

    // Create a temporary directory with test files
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write test files
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "Hello, ASAR!" });
    try tmp_dir.dir.createDirPath(io, "subdir");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "subdir/nested.txt", .data = "Nested file" });

    // Get paths
    var tmp_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPath(io, &tmp_path_buffer);
    const tmp_path = tmp_path_buffer[0..tmp_path_len];

    const output_path = try std.fmt.allocPrint(test_allocator, "{s}/test.asar", .{tmp_path});
    defer test_allocator.free(output_path);

    // Pack the directory
    const patterns: []const []const u8 = &.{};
    try writer.pack(test_allocator, io, tmp_path, output_path, patterns);

    // Open and read back
    var archive = try reader.AsarArchive.open(test_allocator, io, output_path);
    defer archive.close();

    // Read files
    const data1 = try archive.readFile("test.txt");
    defer test_allocator.free(data1);
    try testing.expectEqualStrings("Hello, ASAR!", data1);

    const data2 = try archive.readFile("subdir/nested.txt");
    defer test_allocator.free(data2);
    try testing.expectEqualStrings("Nested file", data2);

    // Missing files surface as an error
    try testing.expectError(error.FileNotFound, archive.readFile("missing.txt"));
}

test "archive layout matches electron asar format" {
    const testing = std.testing;
    const test_allocator = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "Hello, ASAR!" });

    var tmp_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPath(io, &tmp_path_buffer);
    const tmp_path = tmp_path_buffer[0..tmp_path_len];

    const output_path = try std.fmt.allocPrint(test_allocator, "{s}/layout.asar", .{tmp_path});
    defer test_allocator.free(output_path);

    try writer.pack(test_allocator, io, tmp_path, output_path, &.{});

    const raw = try std.Io.Dir.cwd().readFileAlloc(io, output_path, test_allocator, .unlimited);
    defer test_allocator.free(raw);

    // [8 bytes: header size as u64 little-endian][JSON header][padding][data]
    try testing.expect(raw.len > 8);
    const header_size = std.mem.readInt(u64, raw[0..8], .little);
    const header_json = raw[8 .. 8 + header_size];

    // Offsets are serialized as strings, per Electron's format
    try testing.expect(std.mem.indexOf(u8, header_json, "\"hello.txt\":{\"size\":12,\"offset\":\"0\"}") != null);

    // File data starts 4-byte aligned right after the header
    const data_offset = 8 + header_size + asar.calculatePadding(8 + header_size);
    try testing.expectEqual(@as(u64, 0), data_offset % 4);
    try testing.expectEqualStrings("Hello, ASAR!", raw[data_offset .. data_offset + 12]);
}

test "unpack patterns exclude files from the archive" {
    const testing = std.testing;
    const test_allocator = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(io, .{ .sub_path = "regular.txt", .data = "Regular file" });
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "native.node", .data = "Native module" });

    var tmp_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPath(io, &tmp_path_buffer);
    const tmp_path = tmp_path_buffer[0..tmp_path_len];

    const output_path = try std.fmt.allocPrint(test_allocator, "{s}/unpack.asar", .{tmp_path});
    defer test_allocator.free(output_path);

    try writer.pack(test_allocator, io, tmp_path, output_path, &.{"*.node"});

    // Packed file is readable; unpacked file is absent from the archive
    var archive = try reader.AsarArchive.open(test_allocator, io, output_path);
    defer archive.close();

    const data = try archive.readFile("regular.txt");
    defer test_allocator.free(data);
    try testing.expectEqualStrings("Regular file", data);

    try testing.expectError(error.FileNotFound, archive.readFile("native.node"));

    // Unpacked file is copied next to the archive
    const unpacked_path = try std.fmt.allocPrint(test_allocator, "{s}.unpacked/native.node", .{output_path});
    defer test_allocator.free(unpacked_path);

    const unpacked = try std.Io.Dir.cwd().readFileAlloc(io, unpacked_path, test_allocator, .unlimited);
    defer test_allocator.free(unpacked);
    try testing.expectEqualStrings("Native module", unpacked);
}
