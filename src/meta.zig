//! Izo Metadata Type System
//!
//! Defines field mapping rules and metadata structures for comptime code generation

const std = @import("std");

/// Nested configuration - supports both alias and nested Mapper simultaneously
pub const NestedConfig = struct {
    /// Field alias
    alias: ?[]const u8 = null,
    /// Nested Mapper type
    nested: ?type = null,
};

/// Field mapping rules
pub const FieldRule = union(enum) {
    /// Use original field name (default behavior)
    default,
    /// Use alias for serialization/deserialization
    alias: []const u8,
    /// Completely skip this field
    skip,
    /// Default value when missing during deserialization
    default_value: DefaultValue,
    /// Use nested Mapper (for struct fields)
    nested: type,
    /// Combined configuration: alias + nested Mapper
    combined: NestedConfig,

    /// Default value wrapper - stores arbitrary default values at comptime
    pub const DefaultValue = struct {
        // Use type erasure to store default values
        // Actual values are reconstructed from comptime type information
        _type_id: usize = 0,
    };
};

/// Union for storing comptime-known default values
pub const DefaultValueUnion = union(enum) {
    none,
    int: i64,
    uint: u64,
    float: f64,
    bool: bool,
    string: []const u8,
};

/// Field metadata - generated at comptime
///
/// Contains all information needed for serialization/deserialization
pub const FieldMeta = struct {
    /// Zig field name
    name: []const u8,
    /// JSON/Protobuf field name (considering alias)
    serialized_name: []const u8,
    /// Whether this field should be skipped
    should_skip: bool,
    /// Field index in the struct
    index: usize,
    /// Whether a nested Mapper exists
    has_nested_mapper: bool,
    /// Nested Mapper type (if exists)
    nested_mapper: type,
    /// Whether has default value
    has_default_value: bool,
    /// Default value (if exists)
    default_value: DefaultValueUnion,
};

/// Type mapping metadata - generated at comptime
///
/// Contains all field mapping information for a struct type
pub const TypeMeta = struct {
    /// Field metadata array
    fields: []const FieldMeta,
    // Note: Zig doesn't support storing type in comptime structs
    // _type: type,
};

/// Generate field metadata from struct type at comptime
///
/// Example:
/// ```zig
/// const MyStruct = struct { name: []const u8, age: u32 };
/// const fields = comptime generateFieldMeta(MyStruct, .{
///     .name = .{ .alias = "person_name" },
/// });
/// ```
pub fn generateFieldMeta(comptime T: type, comptime config: anytype) []const FieldMeta {
    // Verify T is a struct type
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("generateFieldMeta requires a struct type, got " ++ @typeName(T));
    }

    const struct_info = type_info.@"struct";

    // Use recursive comptime function to build field metadata array
    // This avoids comptime var lifetime issues
    return comptime generateFieldsRecursive(struct_info.fields, config, 0, &[_]FieldMeta{});
}

/// Recursively build field metadata array
fn generateFieldsRecursive(
    comptime all_fields: anytype,
    comptime config: anytype,
    comptime index: usize,
    comptime accumulated: []const FieldMeta,
) []const FieldMeta {
    // Base case: all fields processed
    if (index >= all_fields.len) {
        return accumulated;
    }

    const field = all_fields[index];
    const rule = getFieldRule(config, field.name);

    // Determine serialized name
    const serialized_name = comptime getSerializedName(field.name, rule);

    // Determine if has nested Mapper
    const has_nested = comptime switch (rule) {
        .nested => true,
        .combined => |combined| combined.nested != null,
        else => false,
    };

    // Determine nested Mapper type
    const nested_type = comptime switch (rule) {
        .nested => |n| n,
        .combined => |combined| combined.nested orelse void,
        else => void,
    };

    const new_field_meta = FieldMeta{
        .name = field.name,
        .serialized_name = serialized_name,
        .should_skip = rule == .skip,
        .index = index,
        .has_nested_mapper = has_nested,
        .nested_mapper = nested_type,
        .has_default_value = false,
        .default_value = .none,
    };

    // Recursively process next field
    const new_accumulated = accumulated ++ [_]FieldMeta{new_field_meta};
    return generateFieldsRecursive(all_fields, config, index + 1, new_accumulated);
}

/// Get the rule for a specific field from config
fn getFieldRule(comptime config: anytype, comptime field_name: []const u8) FieldRule {
    const ConfigType = @TypeOf(config);
    const config_info = @typeInfo(ConfigType);

    // Verify config is a struct type
    if (config_info != .@"struct") {
        @compileError("Mapper config must be a struct literal");
    }

    // Iterate over config fields to find matching field name
    inline for (config_info.@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, field_name)) {
            const raw_value = @field(config, field.name);
            const raw_type = @TypeOf(raw_value);

            // Check if it's directly a FieldRule type (e.g., .skip, .default, .nested(...))
            if (raw_type == FieldRule) {
                return raw_value;
            }

            // Check if it's an anonymous struct literal
            const raw_type_info = @typeInfo(raw_type);
            if (raw_type_info == .@"struct") {
                const struct_fields = raw_type_info.@"struct".fields;

                // Collect all configuration items
                var has_alias: bool = false;
                var alias_value: ?[]const u8 = null;
                var has_nested: bool = false;
                var nested_value: ?type = null;
                var has_default_value: bool = false;

                inline for (struct_fields) |struct_field| {
                    if (comptime std.mem.eql(u8, struct_field.name, "alias")) {
                        has_alias = true;
                        alias_value = raw_value.alias;
                    } else if (comptime std.mem.eql(u8, struct_field.name, "nested")) {
                        has_nested = true;
                        nested_value = raw_value.nested;
                    } else if (comptime std.mem.eql(u8, struct_field.name, "default_value")) {
                        has_default_value = true;
                    }
                }

                // If has alias and nested, return combined rule
                if (has_alias and has_nested) {
                    return FieldRule{
                        .combined = .{
                            .alias = alias_value,
                            .nested = nested_value,
                        },
                    };
                }

                // Only alias
                if (has_alias) {
                    return FieldRule{ .alias = alias_value.? };
                }

                // Only nested
                if (has_nested) {
                    return FieldRule{ .nested = nested_value.? };
                }

                // Only default_value
                if (has_default_value) {
                    return FieldRule{ .default_value = .{} };
                }
            }

            // Check if it's an enum literal (e.g., .skip, .default)
            if (raw_type_info == .enum_literal) {
                const literal_name = @tagName(raw_value);

                if (comptime std.mem.eql(u8, literal_name, "skip")) {
                    return .skip;
                } else if (comptime std.mem.eql(u8, literal_name, "default")) {
                    return .default;
                }
            }

            return .default;
        }
    }

    return .default;
}

/// Get serialized name based on rule
fn getSerializedName(comptime field_name: []const u8, comptime rule: FieldRule) []const u8 {
    return switch (rule) {
        .alias => |alias| alias,
        .combined => |combined| combined.alias orelse field_name,
        .default, .skip, .default_value, .nested => field_name,
    };
}

/// Check if type needs recursive processing (struct or array)
pub fn isComplexType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        .array => true,
        .pointer => |ptr| ptr.size == .slice,
        else => false,
    };
}

// ==================== Tests ====================

test "FieldRule - basic rules" {
    const rule1: FieldRule = .default;
    const rule2: FieldRule = .{ .alias = "new_name" };
    const rule3: FieldRule = .skip;

    try std.testing.expect(rule1 == .default);
    try std.testing.expect(rule2 == .alias);
    try std.testing.expect(std.mem.eql(u8, rule2.alias, "new_name"));
    try std.testing.expect(rule3 == .skip);
}

test "generateFieldMeta - basic struct" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const fields = comptime generateFieldMeta(Person, .{});

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(std.mem.eql(u8, fields[0].name, "name"));
    try std.testing.expect(std.mem.eql(u8, fields[0].serialized_name, "name"));
    try std.testing.expect(!fields[0].should_skip);
}

test "generateFieldMeta - with alias" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const fields = comptime generateFieldMeta(Person, .{
        .name = .{ .alias = "person_name" },
    });

    try std.testing.expect(std.mem.eql(u8, fields[0].serialized_name, "person_name"));
    try std.testing.expect(std.mem.eql(u8, fields[1].serialized_name, "age"));
}

test "generateFieldMeta - with skip" {
    const Person = struct {
        name: []const u8,
        secret: []const u8,
    };

    const fields = comptime generateFieldMeta(Person, .{
        .secret = .skip,
    });

    try std.testing.expect(!fields[0].should_skip);
    try std.testing.expect(fields[1].should_skip);
}

test "isComplexType" {
    const SimpleStruct = struct { x: i32 };

    try std.testing.expect(isComplexType(SimpleStruct));
    try std.testing.expect(isComplexType([]const u8));
    try std.testing.expect(isComplexType([10]u8));
    try std.testing.expect(!isComplexType(i32));
    // Note: Last test is same as second, skipped
}
