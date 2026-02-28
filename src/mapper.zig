//! Izo Mapper - Type mapping system
//!
//! Mapper generates configuration for struct types.
//! This module is format-agnostic - serialization implementations are in format-specific modules.

const std = @import("std");
const meta_module = @import("meta.zig");

/// Mapper configuration type
///
/// Usage example:
/// ```zig
/// const Person = struct {
///     name: []const u8,
///     age: u32,
///     secret: []const u8,
/// };
///
/// const PersonMapper = izo.Mapper(Person, .{
///     .name = .{ .alias = "person_name" },
///     .secret = .skip,
/// });
/// ```
pub fn Mapper(comptime T: type, comptime config: anytype) type {
    // Validate config type
    const ConfigType = @TypeOf(config);
    const config_info = @typeInfo(ConfigType);
    if (config_info != .@"struct") {
        @compileError("Mapper config must be a struct literal, got " ++ @typeName(ConfigType));
    }

    // Detect type kind and dispatch to appropriate mapper
    const type_info = @typeInfo(T);

    // Handle Union types
    if (type_info == .@"union") {
        return UnionMapper(T, config);
    }

    // Handle Enum types
    if (type_info == .@"enum") {
        return EnumMapper(T, config);
    }

    // Verify T is a struct (original behavior)
    if (type_info != .@"struct") {
        @compileError("Mapper requires a struct, union, or enum type, got " ++ @typeName(T));
    }

    // Generate field metadata at comptime
    const fields_meta = comptime meta_module.generateFieldMeta(T, config);

    return struct {
        /// Target type for mapping
        pub const TargetType = T;

        /// Precomputed field metadata array
        pub const fields: []const meta_module.FieldMeta = fields_meta;

        /// Get serialized name for a field
        pub fn getSerializedName(comptime field_name: []const u8) []const u8 {
            inline for (fields) |field| {
                if (comptime std.mem.eql(u8, field.name, field_name)) {
                    return field.serialized_name;
                }
            }
            @compileError("Field '" ++ field_name ++ "' not found in " ++ @typeName(T));
        }

        /// Check if field should be skipped
        pub fn shouldSkipField(comptime field_name: []const u8) bool {
            inline for (fields) |field| {
                if (comptime std.mem.eql(u8, field.name, field_name)) {
                    return field.should_skip;
                }
            }
            @compileError("Field '" ++ field_name ++ "' not found in " ++ @typeName(T));
        }

        /// Get count of non-skipped fields (computed at comptime)
        pub fn getActiveFieldCount() usize {
            return comptime blk: {
                var count: usize = 0;
                for (fields) |field| {
                    if (!field.should_skip) count += 1;
                }
                break :blk count;
            };
        }

        /// Find field metadata by serialized name
        /// Used for field matching during deserialization
        pub fn findFieldBySerializedName(serialized_name: []const u8) ?meta_module.FieldMeta {
            inline for (fields) |field| {
                if (field.should_skip) continue;
                if (std.mem.eql(u8, field.serialized_name, serialized_name)) {
                    return field;
                }
            }
            return null;
        }
    };
}

// ==================== Union Mapper ====================

/// Create a Mapper for Union types with special serialization strategies
/// Create a Mapper for Union types
fn UnionMapper(comptime T: type, comptime config: anytype) type {
    // Extract union strategy from config
    const strategy = comptime getUnionStrategy(config);

    return struct {
        pub const TargetType = T;

        /// Union serialization strategy
        pub const union_strategy = strategy;
    };
}

/// Extract union strategy from config
fn getUnionStrategy(comptime config: anytype) meta_module.UnionStrategy {
    const config_info = @typeInfo(@TypeOf(config));
    if (config_info != .@"struct") return .bare;

    inline for (config_info.@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "union_strategy")) {
            const strategy = @field(config, "union_strategy");
            const strategy_type = @TypeOf(strategy);
            const strategy_info = @typeInfo(strategy_type);

            // Check if it's a UnionStrategy type (union(enum))
            if (strategy_info == .@"union" and strategy_info.@"union".tag_type != null) {
                return strategy;
            }

            // Check if it's an anonymous struct literal
            if (strategy_info == .@"struct") {
                // Try to construct UnionStrategy from struct fields
                var has_bare = false;
                var discriminant: ?[]const u8 = null;

                inline for (strategy_info.@"struct".fields) |strat_field| {
                    if (comptime std.mem.eql(u8, strat_field.name, "bare")) {
                        has_bare = true;
                    } else if (comptime std.mem.eql(u8, strat_field.name, "discriminated")) {
                        discriminant = @field(strategy, "discriminated");
                    }
                }

                if (has_bare) {
                    return .bare;
                }

                if (discriminant) |d| {
                    return .{ .discriminated = d };
                }
            }
        }
    }

    // Default: bare mode for scalar unions
    return .bare;
}

/// Get the discriminant value for a variant
/// First tries to find a field with the discriminant name and return its default value
/// Falls back to the variant name (tag name)
fn getDiscriminantValue(comptime VariantType: type, comptime discriminant: []const u8, comptime tag_name: []const u8) []const u8 {
    const variant_info = @typeInfo(VariantType);

    // Check if variant has a field matching the discriminant name
    if (variant_info == .@"struct") {
        inline for (variant_info.@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, discriminant)) {
                // Check if it has a default value using defaultValue() method
                if (field.defaultValue()) |default_val| {
                    if (@TypeOf(default_val) == []const u8) {
                        return default_val;
                    }
                }
            }
        }
    }

    // Fall back to tag name
    return tag_name;
}

// ==================== Enum Mapper ====================

/// Enum serialization strategy
pub const EnumStrategy = enum {
    /// String mode - output the enum name as string (default)
    string,
    /// Bare mode - output the integer value
    bare,
    /// Custom mode - use a custom serialization function
    custom,
};

/// Create a Mapper for Enum types with special serialization strategies
fn EnumMapper(comptime T: type, comptime config: anytype) type {
    const type_info = @typeInfo(T);
    if (type_info != .@"enum") {
        @compileError("EnumMapper requires an enum type, got " ++ @typeName(T));
    }

    // Extract enum strategy from config
    const strategy = comptime getEnumStrategy(config);

    // Extract custom serializer if present
    const CustomSerializer = comptime getCustomSerializer(T, config);

    return struct {
        pub const TargetType = T;

        /// Enum serialization strategy
        pub const enum_strategy = strategy;

        /// Custom serializer function (null if not using custom strategy)
        pub const custom_serializer = CustomSerializer;
    };
}

/// Extract enum strategy from config
fn getEnumStrategy(comptime config: anytype) EnumStrategy {
    const config_info = @typeInfo(@TypeOf(config));
    if (config_info != .@"struct") return .string;

    inline for (config_info.@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "enum_strategy")) {
            const strategy = @field(config, "enum_strategy");
            const strategy_type = @TypeOf(strategy);

            // Check if it's an EnumStrategy enum value
            if (strategy_type == EnumStrategy) {
                return strategy;
            }

            // Check if it's an enum literal like .bare, .string, .custom
            const strategy_info = @typeInfo(strategy_type);
            if (strategy_info == .enum_literal) {
                const literal_name = @tagName(strategy);
                if (comptime std.mem.eql(u8, literal_name, "bare")) return .bare;
                if (comptime std.mem.eql(u8, literal_name, "string")) return .string;
                if (comptime std.mem.eql(u8, literal_name, "custom")) return .custom;
            }
        }
    }

    // Default: string mode
    return .string;
}

/// Extract custom serializer function from config
fn getCustomSerializer(comptime T: type, comptime config: anytype) ?*const fn (T) []const u8 {
    const config_info = @typeInfo(@TypeOf(config));
    if (config_info != .@"struct") return null;

    inline for (config_info.@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "custom")) {
            return @field(config, "custom");
        }
    }

    return null;
}

// ==================== Tests ====================

test "Mapper - basic usage" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = Mapper(Person, .{});

    try std.testing.expectEqual(Person, PersonMapper.TargetType);
    try std.testing.expectEqual(@as(usize, 2), PersonMapper.getActiveFieldCount());
}

test "Mapper - with alias" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    try std.testing.expect(std.mem.eql(u8, PersonMapper.getSerializedName("name"), "person_name"));
    try std.testing.expect(std.mem.eql(u8, PersonMapper.getSerializedName("age"), "age"));
}

test "Mapper - with skip" {
    const Person = struct {
        name: []const u8,
        secret: []const u8,
        age: u32,
    };

    const PersonMapper = Mapper(Person, .{
        .secret = .skip,
    });

    try std.testing.expectEqual(@as(usize, 2), PersonMapper.getActiveFieldCount());
    try std.testing.expect(!PersonMapper.shouldSkipField("name"));
    try std.testing.expect(PersonMapper.shouldSkipField("secret"));
    try std.testing.expect(!PersonMapper.shouldSkipField("age"));
}

test "Mapper - findFieldBySerializedName" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    const field_opt = PersonMapper.findFieldBySerializedName("person_name");
    try std.testing.expect(field_opt != null);
    try std.testing.expect(std.mem.eql(u8, field_opt.?.name, "name"));

    const not_found = PersonMapper.findFieldBySerializedName("nonexistent");
    try std.testing.expect(not_found == null);
}

// ==================== Union Tests ====================

test "Mapper - union bare mode metadata" {
    const RequestId = union(enum) {
        string: []const u8,
        number: i64,
    };

    const RequestIdMapper = Mapper(RequestId, .{
        .union_strategy = .bare,
    });

    // Verify union strategy is correctly stored
    try std.testing.expectEqual(RequestId, RequestIdMapper.TargetType);
    try std.testing.expect(std.meta.activeTag(RequestIdMapper.union_strategy) == .bare);
}

test "Mapper - union discriminated mode metadata" {
    const Content = union(enum) {
        text: struct { value: []const u8 },
        image: struct { data: []const u8 },
    };

    const ContentMapper = Mapper(Content, .{
        .union_strategy = .{ .discriminated = "type" },
    });

    // Verify union strategy is correctly stored
    try std.testing.expectEqual(Content, ContentMapper.TargetType);
    try std.testing.expect(std.meta.activeTag(ContentMapper.union_strategy) == .discriminated);
    try std.testing.expectEqualStrings("type", ContentMapper.union_strategy.discriminated);
}
