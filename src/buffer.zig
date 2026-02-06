//! Izo Buffer Pool - Performance optimization through buffer reuse
//!
//! Provides buffer pooling to reduce memory allocations during serialization.

const std = @import("std");

/// Buffer pool for efficient buffer reuse
pub const BufferPool = struct {
    /// Stack of reusable buffers
    buffers: std.ArrayList([]u8),
    /// Default buffer size
    buffer_size: usize,
    /// Maximum number of buffers to keep in pool
    max_pool_size: usize,

    pub fn init(allocator: std.mem.Allocator, buffer_size: usize, max_pool_size: usize) BufferPool {
        return .{
            .buffers = std.ArrayList([]u8).init(allocator),
            .buffer_size = buffer_size,
            .max_pool_size = max_pool_size,
        };
    }

    pub fn deinit(self: *BufferPool, allocator: std.mem.Allocator) void {
        // Free all pooled buffers
        for (self.buffers.items) |buf| {
            allocator.free(buf);
        }
        self.buffers.deinit();
    }

    /// Acquire a buffer from the pool or allocate a new one
    pub fn acquire(self: *BufferPool, allocator: std.mem.Allocator) ![]u8 {
        if (self.buffers.items.len > 0) {
            // Reuse existing buffer
            return self.buffers.pop();
        }
        // Allocate new buffer
        return try allocator.alloc(u8, self.buffer_size);
    }

    /// Return a buffer to the pool for reuse
    pub fn release(self: *BufferPool, allocator: std.mem.Allocator, buffer: []u8) void {
        if (self.buffers.items.len < self.max_pool_size and buffer.len == self.buffer_size) {
            // Return to pool if capacity allows and size matches
            self.buffers.append(buffer) catch {
                allocator.free(buffer);
            };
        } else {
            // Otherwise free immediately
            allocator.free(buffer);
        }
    }
};

/// Reusable string writer that minimizes allocations
pub const ReusableWriter = struct {
    /// Internal buffer
    buffer: std.ArrayList(u8),
    /// Writer interface
    writer: std.ArrayList(u8).Writer,

    pub fn init(allocator: std.mem.Allocator) !ReusableWriter {
        var buffer = std.ArrayList(u8).init(allocator);
        return .{
            .buffer = buffer,
            .writer = buffer.writer(),
        };
    }

    pub fn deinit(self: *ReusableWriter) void {
        self.buffer.deinit();
    }

    /// Clear buffer for reuse without deallocating
    pub fn clear(self: *ReusableWriter) void {
        self.buffer.clearRetainingCapacity();
    }

    /// Get written content as slice
    pub fn getWritten(self: *const ReusableWriter) []const u8 {
        return self.buffer.items;
    }

    /// Write to the buffer
    pub fn write(self: *ReusableWriter, data: []const u8) !void {
        try self.writer.writeAll(data);
    }

    /// Format and write to buffer
    pub fn print(self: *ReusableWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
    }
};

/// Zero-copy view for string slices
///
/// When possible, references the original JSON buffer instead of copying.
pub const StringView = struct {
    /// Pointer to original buffer (if zero-copy)
    original_ptr: ?[*]const u8,
    /// String content
    content: []const u8,

    /// Create a zero-copy view from original buffer
    pub fn initZeroCopy(original: []const u8, start: usize, len: usize) StringView {
        return .{
            .original_ptr = original.ptr,
            .content = original[start .. start + len],
        };
    }

    /// Create an owned copy (requires allocation)
    pub fn initOwned(allocator: std.mem.Allocator, content: []const u8) !StringView {
        const copy = try allocator.dupe(u8, content);
        return .{
            .original_ptr = null,
            .content = copy,
        };
    }

    /// Check if this is a zero-copy view
    pub fn isZeroCopy(self: StringView) bool {
        return self.original_ptr != null;
    }

    /// Get content as string
    pub fn asString(self: StringView) []const u8 {
        return self.content;
    }
};

/// Performance options for encoding/decoding
pub const PerformanceOptions = struct {
    /// Use buffer pooling
    use_buffer_pool: bool = true,
    /// Buffer pool size
    buffer_pool_size: usize = 4096,
    /// Max buffers in pool
    max_pool_buffers: usize = 8,
    /// Enable zero-copy for strings when possible
    enable_zero_copy: bool = true,
    /// Reuse decoder/encoder instances
    reuse_instances: bool = false,
};

// ==================== Tests ====================

test "BufferPool - acquire and release" {
    const allocator = std.testing.allocator;

    var pool = BufferPool.init(allocator, 1024, 4);
    defer pool.deinit(allocator);

    // Acquire buffer
    const buf1 = try pool.acquire(allocator);
    defer pool.release(allocator, buf1);
    try std.testing.expectEqual(@as(usize, 1024), buf1.len);

    // Release and reacquire should reuse
    pool.release(allocator, buf1);
    const buf2 = try pool.acquire(allocator);
    defer pool.release(allocator, buf2);

    // Buffer should be reused (same pointer)
    try std.testing.expectEqual(buf1.ptr, buf2.ptr);
}

test "ReusableWriter - clear and reuse" {
    const allocator = std.testing.allocator;

    var writer = try ReusableWriter.init(allocator);
    defer writer.deinit();

    // Write first content
    try writer.write("Hello");
    try std.testing.expectEqualStrings("Hello", writer.getWritten());

    // Clear
    writer.clear();
    try std.testing.expectEqual(@as(usize, 0), writer.getWritten().len);

    // Write second content
    try writer.write("World");
    try std.testing.expectEqualStrings("World", writer.getWritten());
}

test "StringView - zero copy" {
    const original = "Hello, World!";

    const view = StringView.initZeroCopy(original, 7, 5);
    try std.testing.expect(view.isZeroCopy());
    try std.testing.expectEqualStrings("World", view.asString());
    try std.testing.expectEqual(original.ptr, view.original_ptr);
}
