const std = @import("std");
const reader = @import("reader.zig");
const writer = @import("writer.zig");

// Use a global allocator for the C API
// In production, we use GPA for safety
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

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
    return reader.AsarArchive.open(allocator, path_slice) catch |err| {
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
    var patterns = std.ArrayList([]const u8).init(allocator);
    defer {
        for (patterns.items) |pattern| {
            allocator.free(pattern);
        }
        patterns.deinit();
    }

    if (unpack_patterns) |patterns_ptr| {
        var i: usize = 0;
        while (i < pattern_count) : (i += 1) {
            const pattern_cstr = patterns_ptr[i];
            const pattern_slice = std.mem.span(pattern_cstr);
            const owned_pattern = allocator.dupe(u8, pattern_slice) catch return 0;
            patterns.append(owned_pattern) catch return 0;
        }
    }

    writer.pack(allocator, source_slice, output_slice, patterns.items) catch |err| {
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

    // Create a temporary directory with test files
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write test files
    try tmp_dir.dir.writeFile(.{ .sub_path = "test.txt", .data = "Hello, ASAR!" });
    try tmp_dir.dir.makeDir("subdir");
    try tmp_dir.dir.writeFile(.{ .sub_path = "subdir/nested.txt", .data = "Nested file" });

    // Get paths
    const tmp_path = try tmp_dir.dir.realpathAlloc(test_allocator, ".");
    defer test_allocator.free(tmp_path);

    const output_path = try std.fmt.allocPrint(test_allocator, "{s}/test.asar", .{tmp_path});
    defer test_allocator.free(output_path);

    // Pack the directory
    const patterns: []const []const u8 = &.{};
    try writer.pack(test_allocator, tmp_path, output_path, patterns);

    // Open and read back
    var archive = try reader.AsarArchive.open(test_allocator, output_path);
    defer archive.close();

    // Read files
    const data1 = try archive.readFile("test.txt");
    defer test_allocator.free(data1);
    try testing.expectEqualStrings("Hello, ASAR!", data1);

    const data2 = try archive.readFile("subdir/nested.txt");
    defer test_allocator.free(data2);
    try testing.expectEqualStrings("Nested file", data2);
}
