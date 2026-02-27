//! Izomorph (Izo) - Structure-preserving serialization library
//!
//! **Slogan:** Structure-preserving serialization for the Zig ecosystem.
//! Define once, encode anywhere.
//!
//! Core Concepts:
//! - Establish structure-preserving mapping (isomorphism) between memory representation and transmission representation
//! - Leverage Zig's comptime for zero-cost abstractions
//! - Define mapping rules once, support multiple serialization formats
//!
//! Usage Example:
//! ```zig
//! const izo = @import("izomorph");
//!
//! const Person = struct {
//!     name: []const u8,
//!     age: u32,
//!     secret: []const u8,
//! };
//!
//! // Define isomorphism mapping rules
//! const PersonMapper = izo.Mapper(Person, .{
//!     .name = .{ .alias = "person_name" },  // Field alias
//!     .secret = .skip,                       // Skip field
//! });
//!
//! // Encode to JSON
//! const json_str = try izo.json.encode(allocator, person, PersonMapper, .{});
//!
//! // Decode from JSON
//! const decoded = try izo.json.decode(allocator, PersonMapper, json_str);
//! ```

const std = @import("std");

// ==================== Core Module Exports ====================

/// Type metadata system
pub const meta = @import("meta.zig");

/// Error handling module
pub const errors = @import("error.zig");

/// Buffer pool for performance optimization
pub const buffer = @import("buffer.zig");

/// Mapper core structure
pub const Mapper = @import("mapper.zig").Mapper;

/// JSON serialization module
pub const json = struct {
    /// JSON encoder
    pub const encode = @import("json/encode.zig").encode;
    /// JSON encoder to writer (zero-allocation streaming)
    pub const encodeToWriter = @import("json/encode.zig").encodeToWriter;
    /// Encoding options
    pub const EncodeOptions = @import("json/encode.zig").EncodeOptions;
    /// JSON decoder
    pub const decode = @import("json/decode.zig").decode;
    /// JSON decoder from reader (streaming)
    pub const decodeFromReader = @import("json/decode.zig").decodeFromReader;
    /// Decoding options
    pub const DecodeOptions = @import("json/decode.zig").DecodeOptions;
};

// ==================== Integration Tests ====================

test "izomorph - full API usage" {
    const allocator = std.testing.allocator;

    // Define test struct
    const Person = struct {
        name: []const u8,
        age: u32,
        email: []const u8,
    };

    // Define mapping rules
    const PersonMapper = Mapper(Person, .{
        .name = .{ .alias = "person_name" },
        .email = .skip,
    });

    // Create test data
    const person = Person{
        .name = "Alice",
        .age = 30,
        .email = "alice@example.com",
    };

    // Encode to JSON
    const json_str = try json.encode(allocator, person, PersonMapper, .{});
    defer allocator.free(json_str);

    // Verify complete JSON output
    try std.testing.expectEqualStrings("{\"person_name\":\"Alice\",\"age\":30}", json_str);

    // Decode JSON
    const decoded = try json.decode(allocator, PersonMapper, json_str);
    try std.testing.expectEqualStrings("Alice", decoded.name);
    try std.testing.expectEqual(@as(u32, 30), decoded.age);
}
