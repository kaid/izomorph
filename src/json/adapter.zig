//! JSON Adapter - Implements serialization/deserialization for JSON format
//!
//! This module provides format-specific implementations for Mapper configurations.

const std = @import("std");
const meta_module = @import("../meta.zig");
const mapper_module = @import("../mapper.zig");
const root_codec = @import("root_codec.zig");
const EnumStrategy = mapper_module.EnumStrategy;

/// Check if value equals the default value
fn isDefaultValue(value: anytype, comptime default: meta_module.DefaultValueUnion) bool {
    return switch (default) {
        .none => false,
        .int => |v| value == v,
        .uint => |v| value == v,
        .float => |v| value == v,
        .bool => |v| value == v,
        .string => |v| blk: {
            const T = @TypeOf(value);
            if (T == []const u8 or T == []u8) {
                break :blk std.mem.eql(u8, value, v);
            }
            break :blk false;
        },
    };
}

/// Check if value equals type's default value
fn isTypeDefault(value: anytype) bool {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info == .optional) return value == null;
    if (info == .bool) return value == false;
    if (info == .int or info == .comptime_int) return value == 0;
    if (info == .float or info == .comptime_float) return value == 0.0;
    if (info == .pointer) {
        if (info.pointer.size == .Slice) return value.len == 0;
        return false;
    }
    if (info == .@"enum") return @intFromEnum(value) == 0;
    return false;
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

/// Write array with element mapper applied to each element (top-level function)
fn writeArrayWithElementMapper(jws: anytype, array: anytype, comptime ElementMapper: type) !void {
    const ElementAdapter = createAdapter(ElementMapper);
    // Unwrap optional array/slice if present
    const info = @typeInfo(@TypeOf(array));
    if (info == .optional) {
        if (array) |payload| {
            try jws.beginArray();
            for (payload) |element| {
                const element_adapter = ElementAdapter{ .value = element };
                try jws.write(element_adapter);
            }
            try jws.endArray();
        } else {
            try jws.write(null);
        }
    } else {
        try jws.beginArray();
        for (array) |element| {
            const element_adapter = ElementAdapter{ .value = element };
            try jws.write(element_adapter);
        }
        try jws.endArray();
    }
}

/// Write struct fields to JSON using the given Mapper
/// This is the core field serialization logic extracted for reuse
fn writeStructFields(value: anytype, jws: anytype, comptime MapperType: type) !void {
    const fields = MapperType.fields;

    // Iterate over all fields
    inline for (fields) |field_meta| {
        if (field_meta.should_skip) continue;

        // Get field value
        const field_value = @field(value, field_meta.name);

        // Check skip
        var should_process = true;

        // Check omit_null
        if (comptime field_meta.omit_null) {
            if (field_value == null) should_process = false;
        }

        // Check omit_default
        if (should_process and comptime field_meta.omit_default) {
            if (field_meta.has_default_value) {
                if (isDefaultValue(field_value, field_meta.default_value)) should_process = false;
            } else {
                // If no default specified in rules, use type's default (e.g., false, 0, null)
                if (isTypeDefault(field_value)) should_process = false;
            }
        }

        if (should_process and field_meta.strategy != .skip) {
            // Use mapped field name
            try jws.objectField(field_meta.serialized_name);

            // Handle based on strategy
            switch (field_meta.strategy) {
                .skip => unreachable, // Should have been filtered out above
                .default => {
                    // Check if field type has its own Mapper
                    const FieldType = @TypeOf(field_value);
                    const InnerType = comptime blk: {
                        const type_info = @typeInfo(FieldType);
                        if (type_info == .optional) {
                            break :blk type_info.optional.child;
                        }
                        break :blk FieldType;
                    };

                    if (comptime hasMapper(InnerType)) {
                        const FieldMapper = getTypeMapper(InnerType);
                        const FieldAdapter = createAdapter(FieldMapper);

                        const type_info = @typeInfo(FieldType);
                        if (type_info == .optional) {
                            if (field_value) |payload| {
                                try jws.write(FieldAdapter{ .value = payload });
                            } else {
                                try jws.write(null);
                            }
                        } else {
                            try jws.write(FieldAdapter{ .value = field_value });
                        }
                    } else if (comptime field_meta.has_element_mapper) {
                        try writeArrayWithElementMapper(jws, field_value, field_meta.element_mapper);
                    } else {
                        // No element mapper configured - try to auto-detect from element type's pub const Mapper
                        const MaybeElementMapper: ?type = comptime blk2: {
                            // Extract element type from array/slice (handles ?[]T and []T)
                            var ArrayOrOptionalType = @TypeOf(field_value);
                            var type_info = @typeInfo(ArrayOrOptionalType);

                            // Unwrap optional if present
                            if (type_info == .optional) {
                                ArrayOrOptionalType = type_info.optional.child;
                                type_info = @typeInfo(ArrayOrOptionalType);
                            }

                            // Check if it's a slice
                            if (type_info == .pointer and type_info.pointer.size == .slice) {
                                const ElementType = type_info.pointer.child;
                                // Check if element type is a composite type that can have declarations
                                const element_type_info = @typeInfo(ElementType);
                                const isCompositeType = element_type_info == .@"struct" or
                                    element_type_info == .@"union" or
                                    element_type_info == .@"enum" or
                                    element_type_info == .@"opaque";
                                // Check if element type has pub const Mapper
                                if (isCompositeType and @hasDecl(ElementType, "Mapper")) {
                                    break :blk2 ElementType.Mapper;
                                }
                            }
                            break :blk2 null;
                        };
                        if (MaybeElementMapper) |ElementMapper| {
                            try writeArrayWithElementMapper(jws, field_value, ElementMapper);
                        } else {
                            try jws.write(field_value);
                        }
                    }
                },
                .nested => |NestedMapper| {
                    const NestedAdapter = createAdapter(NestedMapper);
                    const info = @typeInfo(@TypeOf(field_value));
                    if (info == .optional) {
                        if (field_value) |payload| {
                            try jws.write(NestedAdapter{ .value = payload });
                        } else {
                            try jws.write(null);
                        }
                    } else {
                        try jws.write(NestedAdapter{ .value = field_value });
                    }
                },
                .nested_lazy => |getMapper| {
                    // Lazy evaluation to avoid comptime circular dependency
                    const NestedMapper = comptime getMapper();
                    const NestedAdapter = createAdapter(NestedMapper);
                    const info = @typeInfo(@TypeOf(field_value));
                    if (info == .optional) {
                        if (field_value) |payload| {
                            // Handle single-item pointer types (e.g., *const T) by dereferencing
                            // Slice types (e.g., []const T) are passed directly
                            const payload_info = @typeInfo(@TypeOf(payload));
                            if (payload_info == .pointer and payload_info.pointer.size == .one) {
                                try jws.write(NestedAdapter{ .value = payload.* });
                            } else {
                                try jws.write(NestedAdapter{ .value = payload });
                            }
                        } else {
                            try jws.write(null);
                        }
                    } else {
                        // Handle single-item pointer types (e.g., *const T) by dereferencing
                        // Slice types (e.g., []const T) are passed directly
                        if (info == .pointer and info.pointer.size == .one) {
                            try jws.write(NestedAdapter{ .value = field_value.* });
                        } else {
                            try jws.write(NestedAdapter{ .value = field_value });
                        }
                    }
                },
                .custom => |custom_config| {
                    if (comptime custom_config.hasSerializer()) {
                        const Serializer = custom_config.to;
                        // Check if serializer accepts helpers parameter (3 params: value, jws, helpers)
                        const has_helpers = comptime blk: {
                            const SerializeFn = @TypeOf(Serializer.serialize);
                            const info = @typeInfo(SerializeFn);
                            if (info == .@"fn") {
                                break :blk info.@"fn".params.len == 3;
                            }
                            break :blk false;
                        };

                        if (has_helpers) {
                            // Serializer supports helpers - check if mappers are provided
                            const mappers = comptime custom_config.getMappers();
                            if (mappers.len > 0) {
                                const HelpersType = Helpers(mappers, @TypeOf(jws));
                                const helpers = HelpersType{ .jws = jws };
                                try Serializer.serialize(field_value, jws, helpers);
                            } else {
                                // No mappers configured, pass dummy helpers
                                const DummyHelpers = struct {
                                    jws2: @TypeOf(jws),
                                    pub fn writeMapped(self: @This(), val: anytype) !void {
                                        try self.jws2.write(val);
                                    }
                                };
                                const dummy = DummyHelpers{ .jws2 = jws };
                                try Serializer.serialize(field_value, jws, dummy);
                            }
                        } else {
                            // Legacy serializer without helpers support
                            try Serializer.serialize(field_value, jws);
                        }
                    } else {
                        // Fallback to default
                        try jws.write(field_value);
                    }
                },
            }
        }
    }
}

/// Create a type-to-mapper lookup table at comptime
/// Returns the mapper type for a given value type, or null if not found
/// Handles optional, pointer, and pointer-to-array types by unwrapping to the base type
fn findMapperForType(comptime ValueType: type, comptime mappers: []const type) ?type {
    // Unwrap the type to find the base type (handles ?T, *T, *const T, etc.)
    const BaseType = comptime blk: {
        var t = ValueType;
        while (true) {
            const info = @typeInfo(t);
            if (info == .optional) {
                t = info.optional.child;
            } else if (info == .pointer) {
                t = info.pointer.child;
            } else {
                break;
            }
        }
        break :blk t;
    };

    inline for (mappers) |MapperType| {
        if (BaseType == MapperType.TargetType) {
            return MapperType;
        }
    }
    return null;
}

/// Create a custom serializer helpers object that provides auto-mapping capabilities
fn Helpers(comptime mappers: []const type, comptime Jws: type) type {
    return struct {
        /// The JSON WriteStream
        jws: Jws,

        /// Write a value to JSON, automatically applying a matching mapper if available
        /// Falls back to standard serialization if no mapper matches
        pub fn writeMapped(self: @This(), value: anytype) !void {
            const ValueType = @TypeOf(value);

            @setEvalBranchQuota(10000);
            const mapper_result = comptime findMapperForType(ValueType, mappers);

            if (comptime mapper_result) |MapperType| {
                const Adapter = createAdapter(MapperType);
                try self.jws.write(Adapter{ .value = value });
            } else {
                // No matching mapper, use standard serialization
                try self.jws.write(value);
            }
        }
    };
}

/// Check if a type has a pub const Mapper declaration
/// Only checks composite types (struct, union, enum, opaque), not primitives
fn hasMapper(comptime T: type) bool {
    const type_info = @typeInfo(T);
    // Only struct, union, enum, and opaque types can have declarations
    const isCompositeType = type_info == .@"struct" or type_info == .@"union" or
        type_info == .@"enum" or type_info == .@"opaque";

    if (!isCompositeType) return false;

    return @hasDecl(T, "Mapper");
}

/// Get the Mapper for a type (uses pub const Mapper if available, otherwise creates default)
fn getTypeMapper(comptime T: type) type {
    if (comptime hasMapper(T)) {
        return T.Mapper;
    } else {
        // Create a default mapper with no special configuration
        return @import("../mapper.zig").Mapper(T, .{});
    }
}

/// Create a JSON Adapter for struct serialization
pub fn createStructAdapter(comptime MapperType: type) type {
    const T = MapperType.TargetType;

    return struct {
        /// The Mapper type this adapter works with
        pub const Mapper = MapperType;

        /// Serialize a value to JSON
        pub fn stringify(value: T, jws: anytype) !void {
            try jws.beginObject();
            try writeStructFields(value, jws, MapperType);
            try jws.endObject();
        }

        /// Parse from JSON source
        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!T {
            // Verify input is object begin
            if (.object_begin != try source.next()) return error.UnexpectedToken;

            // Create result struct
            var result: T = undefined;
            var fields_seen = [_]bool{false} ** Mapper.fields.len;

            // Parse object fields
            while (true) {
                var name_token: ?std.json.Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse std.json.default_max_value_len);

                const json_field_name = switch (name_token.?) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => break, // No more fields
                    else => return error.UnexpectedToken,
                };

                // Find matching serialized name in Mapper's fields
                var matched = false;
                inline for (Mapper.fields, 0..) |field_meta, i| {
                    if (field_meta.should_skip) continue;

                    if (std.mem.eql(u8, field_meta.serialized_name, json_field_name)) {
                        // Free name token
                        if (name_token) |token| {
                            switch (token) {
                                .allocated_string => |slice| allocator.free(slice),
                                else => {},
                            }
                        }
                        name_token = null;

                        // Handle duplicate fields
                        if (fields_seen[i]) {
                            switch (options.duplicate_field_behavior) {
                                .use_first => {
                                    // Parse and ignore duplicate value
                                    _ = try parseFieldValue(allocator, source, field_meta, options);
                                    matched = true;
                                    break;
                                },
                                .@"error" => return error.DuplicateField,
                                .use_last => {},
                            }
                        }

                        // Parse field value
                        @field(result, field_meta.name) = try parseFieldValue(allocator, source, field_meta, options);
                        fields_seen[i] = true;
                        matched = true;
                        break;
                    }
                }

                // If no matching field
                if (!matched) {
                    if (name_token) |token| {
                        switch (token) {
                            .allocated_string => |slice| allocator.free(slice),
                            else => {},
                        }
                    }

                    if (options.ignore_unknown_fields) {
                        try source.skipValue();
                    } else {
                        return error.UnknownField;
                    }
                }
            }

            // Fill default values (for unparsed fields)
            inline for (Mapper.fields, 0..) |field_meta, i| {
                if (field_meta.should_skip) continue;

                if (!fields_seen[i]) {
                    const field_type = @TypeOf(@field(result, field_meta.name));

                    if (comptime @typeInfo(field_type) == .optional) {
                        // Optional types default to null
                        @field(result, field_meta.name) = null;
                    }
                    // For non-optional types without provided values, keep uninitialized
                    // Better error handling may be needed in production applications
                }
            }

            return result;
        }

        /// Parse single field value
        fn parseFieldValue(
            allocator: std.mem.Allocator,
            source: anytype,
            comptime field_meta: meta_module.FieldMeta,
            options: std.json.ParseOptions,
        ) !@TypeOf(@field(@as(T, undefined), field_meta.name)) {
            const FieldType = @TypeOf(@field(@as(T, undefined), field_meta.name));

            // Ensure options allocate and max_value_len are set
            var actual_options = options;
            if (actual_options.allocate == null) {
                actual_options.allocate = .alloc_if_needed;
            }
            if (actual_options.max_value_len == null) {
                actual_options.max_value_len = std.json.default_max_value_len;
            }

            // Handle based on strategy
            switch (field_meta.strategy) {
                .skip => {
                    // Skip the value
                    try source.skipValue();
                    // Return default value
                    return undefined;
                },
                .default => {
                    // If has element Mapper for arrays/slices
                    if (comptime field_meta.has_element_mapper) {
                        const ElementType = @typeInfo(FieldType).pointer.child;
                        return try parseArrayWithElementMapper(ElementType, allocator, source, field_meta.element_mapper, actual_options);
                    }
                    // Otherwise use standard parsing
                    return try std.json.innerParse(FieldType, allocator, source, actual_options);
                },
                .nested => |NestedMapper| {
                    const NestedAdapter = createAdapter(NestedMapper);
                    return try NestedAdapter.jsonParse(allocator, source, actual_options);
                },
                .nested_lazy => |getMapper| {
                    // Lazy evaluation to avoid comptime circular dependency
                    const NestedMapper = comptime getMapper();
                    const NestedAdapter = createAdapter(NestedMapper);
                    return try NestedAdapter.jsonParse(allocator, source, actual_options);
                },
                .custom => |custom_config| {
                    if (comptime custom_config.hasDeserializer()) {
                        const Deserializer = custom_config.from;
                        return try Deserializer.deserialize(allocator, source);
                    } else {
                        // Fallback to standard parsing
                        return try std.json.innerParse(FieldType, allocator, source, actual_options);
                    }
                },
            }
        }

        /// Parse array with element mapper applied to each element
        fn parseArrayWithElementMapper(
            comptime ElementType: type,
            allocator: std.mem.Allocator,
            source: anytype,
            comptime ElementMapper: type,
            options: std.json.ParseOptions,
        ) ![]const ElementType {
            const ElementAdapter = createAdapter(ElementMapper);

            // Parse array begin
            if (.array_begin != try source.next()) return error.UnexpectedToken;

            var list: std.ArrayList(ElementType) = .empty;
            errdefer list.deinit(allocator);

            // Parse elements until array end
            while (true) {
                if (try source.peekNextTokenType() == .array_end) {
                    _ = try source.next();
                    break;
                }

                const element = try ElementAdapter.jsonParse(allocator, source, options);
                try list.append(allocator, element);
            }

            return list.toOwnedSlice(allocator);
        }
    };
}

/// Create a JSON Adapter for explicit root codecs (top-level array/map).
fn createRootAdapter(comptime RootCodecType: type) type {
    const kind = RootCodecType.kind;

    return struct {
        value: RootCodecType.TargetType,

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            switch (kind) {
                .array_mapper => try stringifyArrayWithMapper(self.value, jws),
                .array_plain => try stringifyArrayPlain(self.value, jws),
                .map_mapper => try stringifyMapWithMapper(self.value, jws),
                .map_plain => try stringifyMapPlain(self.value, jws),
                .map_ordered_mapper => try stringifyMapWithMapper(self.value, jws),
                .map_ordered_plain => try stringifyMapPlain(self.value, jws),
            }
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !RootCodecType.TargetType {
            var actual_options = options;
            if (actual_options.allocate == null) {
                actual_options.allocate = .alloc_if_needed;
            }
            if (actual_options.max_value_len == null) {
                actual_options.max_value_len = std.json.default_max_value_len;
            }

            switch (kind) {
                .array_mapper => return try parseArrayWithMapper(allocator, source, actual_options),
                .array_plain => return try parseArrayPlain(allocator, source, actual_options),
                .map_mapper => return try parseMapWithMapper(allocator, source, actual_options),
                .map_plain => return try parseMapPlain(allocator, source, actual_options),
                .map_ordered_mapper => return try parseMapWithMapper(allocator, source, actual_options),
                .map_ordered_plain => return try parseMapPlain(allocator, source, actual_options),
            }
        }

        fn stringifyArrayWithMapper(value: RootCodecType.TargetType, jws: anytype) !void {
            const ElementAdapter = createAdapter(RootCodecType.ElementMapperType);

            try jws.beginArray();
            for (value) |element| {
                try jws.write(ElementAdapter{ .value = element });
            }
            try jws.endArray();
        }

        fn stringifyArrayPlain(value: RootCodecType.TargetType, jws: anytype) !void {
            try jws.beginArray();
            for (value) |element| {
                try jws.write(element);
            }
            try jws.endArray();
        }

        fn stringifyMapWithMapper(value: RootCodecType.TargetType, jws: anytype) !void {
            const ValueAdapter = createAdapter(RootCodecType.ValueMapperType);

            try jws.beginObject();
            var it = value.iterator();
            while (it.next()) |entry| {
                try jws.objectField(entry.key_ptr.*);
                try jws.write(ValueAdapter{ .value = entry.value_ptr.* });
            }
            try jws.endObject();
        }

        fn stringifyMapPlain(value: RootCodecType.TargetType, jws: anytype) !void {
            try jws.beginObject();
            var it = value.iterator();
            while (it.next()) |entry| {
                try jws.objectField(entry.key_ptr.*);
                try jws.write(entry.value_ptr.*);
            }
            try jws.endObject();
        }

        fn parseArrayWithMapper(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !RootCodecType.TargetType {
            const ElementAdapter = createAdapter(RootCodecType.ElementMapperType);

            if (.array_begin != try source.next()) return error.UnexpectedToken;

            var list: std.ArrayList(RootCodecType.ElementType) = .empty;
            errdefer list.deinit(allocator);

            while (true) {
                if (try source.peekNextTokenType() == .array_end) {
                    _ = try source.next();
                    break;
                }

                const element = try ElementAdapter.jsonParse(allocator, source, options);
                try list.append(allocator, element);
            }

            return list.toOwnedSlice(allocator);
        }

        fn parseArrayPlain(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !RootCodecType.TargetType {
            if (.array_begin != try source.next()) return error.UnexpectedToken;

            var list: std.ArrayList(RootCodecType.ElementType) = .empty;
            errdefer list.deinit(allocator);

            while (true) {
                if (try source.peekNextTokenType() == .array_end) {
                    _ = try source.next();
                    break;
                }

                const element = try std.json.innerParse(RootCodecType.ElementType, allocator, source, options);
                try list.append(allocator, element);
            }

            return list.toOwnedSlice(allocator);
        }

        fn parseMapWithMapper(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !RootCodecType.TargetType {
            const ValueAdapter = createAdapter(RootCodecType.ValueMapperType);

            if (.object_begin != try source.next()) return error.UnexpectedToken;

            var result = RootCodecType.TargetType.init();
            errdefer result.deinit(allocator);

            while (true) {
                const name_token = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
                const json_key = switch (name_token) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => break,
                    else => return error.UnexpectedToken,
                };
                defer switch (name_token) {
                    .allocated_string => |slice| allocator.free(slice),
                    else => {},
                };

                const has_duplicate = result.contains(json_key);
                if (has_duplicate) {
                    switch (options.duplicate_field_behavior) {
                        .use_first => {
                            try source.skipValue();
                            continue;
                        },
                        .@"error" => return error.DuplicateField,
                        .use_last => {},
                    }
                }

                const value = try ValueAdapter.jsonParse(allocator, source, options);
                const owned_key = try allocator.dupe(u8, json_key);
                errdefer allocator.free(owned_key);
                try result.putOwnedKey(allocator, owned_key, value);
            }

            return result;
        }

        fn parseMapPlain(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !RootCodecType.TargetType {
            if (.object_begin != try source.next()) return error.UnexpectedToken;

            var result = RootCodecType.TargetType.init();
            errdefer result.deinit(allocator);

            while (true) {
                const name_token = try source.nextAllocMax(allocator, options.allocate.?, options.max_value_len.?);
                const json_key = switch (name_token) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => break,
                    else => return error.UnexpectedToken,
                };
                defer switch (name_token) {
                    .allocated_string => |slice| allocator.free(slice),
                    else => {},
                };

                const has_duplicate = result.contains(json_key);
                if (has_duplicate) {
                    switch (options.duplicate_field_behavior) {
                        .use_first => {
                            try source.skipValue();
                            continue;
                        },
                        .@"error" => return error.DuplicateField,
                        .use_last => {},
                    }
                }

                const value = try std.json.innerParse(RootCodecType.ValueType, allocator, source, options);
                const owned_key = try allocator.dupe(u8, json_key);
                errdefer allocator.free(owned_key);
                try result.putOwnedKey(allocator, owned_key, value);
            }

            return result;
        }
    };
}

/// Create a JSON Adapter type for the given Mapper
pub fn createAdapter(comptime MapperType: type) type {
    if (comptime root_codec.isRootCodec(MapperType)) {
        return createRootAdapter(MapperType);
    }

    // Check if this is a union mapper, enum mapper, or struct mapper
    const T = MapperType.TargetType;
    const type_info = @typeInfo(T);

    if (type_info == .@"union") {
        return createUnionAdapter(MapperType);
    } else if (type_info == .@"enum") {
        return createEnumAdapter(MapperType);
    } else {
        return createStructAdapterWrapper(MapperType);
    }
}

/// Wrapper that adds jsonStringify interface to struct adapter
fn createStructAdapterWrapper(comptime MapperType: type) type {
    const AdapterImpl = createStructAdapter(MapperType);

    return struct {
        value: MapperType.TargetType,

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try AdapterImpl.stringify(self.value, jws);
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !MapperType.TargetType {
            return try AdapterImpl.jsonParse(allocator, source, options);
        }
    };
}

/// Create a JSON Adapter for union serialization
fn createUnionAdapter(comptime MapperType: type) type {
    const T = MapperType.TargetType;
    const strategy = MapperType.strategy;

    return struct {
        value: T,

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            switch (strategy) {
                .bare => try stringifyBare(self.value, jws),
                .discriminated => |discriminant| try stringifyDiscriminated(self.value, jws, discriminant),
            }
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !T {
            switch (strategy) {
                .bare => return try parseBare(allocator, source, options),
                .discriminated => |discriminant| return try parseDiscriminated(allocator, source, discriminant, options),
            }
        }

        fn parseBare(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !T {
            const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse std.json.default_max_value_len);
            defer switch (token) {
                .allocated_string => |s| allocator.free(s),
                else => {},
            };

            const union_info = @typeInfo(T).@"union";
            switch (token) {
                .string, .allocated_string => |s| {
                    inline for (union_info.fields) |field| {
                        if (field.type == []const u8) {
                            return @unionInit(T, field.name, try allocator.dupe(u8, s));
                        }
                    }
                },
                .number => |n| {
                    inline for (union_info.fields) |f| {
                        if (f.type == i64 or f.type == u64 or f.type == i32 or f.type == u32) {
                            if (std.fmt.parseInt(f.type, n, 10)) |val| {
                                return @unionInit(T, f.name, val);
                            } else |_| {}
                        }
                    }
                },
                else => return error.UnexpectedToken,
            }
            return error.UnexpectedToken;
        }

        fn parseDiscriminated(allocator: std.mem.Allocator, source: anytype, comptime discriminant: []const u8, options: std.json.ParseOptions) !T {
            var val = try std.json.Value.jsonParse(allocator, source, options);
            defer val.deinit();

            const obj = switch (val) {
                .object => |o| o,
                else => return error.UnexpectedToken,
            };

            const type_val = obj.get(discriminant) orelse return error.UnknownField;
            const type_name = switch (type_val) {
                .string => |s| s,
                else => return error.UnexpectedToken,
            };

            const union_info = @typeInfo(T).@"union";
            inline for (union_info.fields) |field| {
                const VariantType = field.type;
                const tag_name = field.name;

                if (std.mem.eql(u8, tag_name, type_name)) {
                    var out = std.ArrayList(u8).init(allocator);
                    defer out.deinit();
                    try std.json.stringify(val, .{}, out.writer());

                    const variant_parsed = try std.json.parseFromSlice(VariantType, allocator, out.items, options);
                    defer variant_parsed.deinit();
                    return @unionInit(T, tag_name, variant_parsed.value);
                }
            }

            return error.UnknownField;
        }

        fn stringifyBare(value: T, jws: anytype) !void {
            switch (value) {
                inline else => |variant_value| {
                    const VariantType = @TypeOf(variant_value);
                    const variant_info = @typeInfo(VariantType);

                    // For struct types, check if there's a Mapper and use it
                    if (variant_info == .@"struct" and comptime hasMapper(VariantType)) {
                        const VariantMapper = getTypeMapper(VariantType);
                        try jws.beginObject();
                        try writeStructFields(variant_value, jws, VariantMapper);
                        try jws.endObject();
                    } else {
                        // For scalar types or structs without Mapper, write directly
                        try jws.write(variant_value);
                    }
                },
            }
        }

        fn stringifyDiscriminated(value: T, jws: anytype, comptime discriminant: []const u8) !void {
            switch (value) {
                inline else => |variant_value, tag| {
                    const field_name = @tagName(tag);
                    return try stringifyDiscriminatedImpl(jws, discriminant, field_name, variant_value);
                },
            }
        }

        fn stringifyDiscriminatedImpl(
            jws: anytype,
            comptime discriminant: []const u8,
            comptime field_name: []const u8,
            variant_value: anytype,
        ) !void {
            const VariantType = @TypeOf(variant_value);
            const variant_info = @typeInfo(VariantType);

            if (variant_info == .@"struct") {
                try jws.beginObject();
                const discriminant_value = comptime getDiscriminantValue(VariantType, discriminant, field_name);
                try jws.objectField(discriminant);
                try jws.write(discriminant_value);

                // Check if variant type has a pub const Mapper - use it if available
                if (comptime hasMapper(VariantType)) {
                    // Use the variant's own Mapper to serialize fields
                    // This ensures omit_null and other mapper rules are respected
                    const VariantMapper = getTypeMapper(VariantType);
                    try writeStructFields(variant_value, jws, VariantMapper);
                } else {
                    // Fallback: manually iterate fields (original behavior)
                    const variant_struct_info = variant_info.@"struct";
                    inline for (variant_struct_info.fields) |variant_field| {
                        if (comptime std.mem.eql(u8, variant_field.name, discriminant)) continue;
                        try jws.objectField(variant_field.name);
                        try jws.write(@field(variant_value, variant_field.name));
                    }
                }
                try jws.endObject();
            } else {
                try jws.beginObject();
                try jws.objectField(discriminant);
                try jws.write(field_name);
                try jws.objectField("value");
                try jws.write(variant_value);
                try jws.endObject();
            }
        }
    };
}

/// Create a JSON Adapter for enum serialization
fn createEnumAdapter(comptime MapperType: type) type {
    const T = MapperType.TargetType;
    const strategy = MapperType.enum_strategy;

    return struct {
        value: T,

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            switch (strategy) {
                .string => {
                    // Default: output enum name as string
                    try jws.write(@tagName(self.value));
                },
                .bare => {
                    // Output integer value
                    try jws.write(@intFromEnum(self.value));
                },
                .custom => |custom_config| {
                    // Check if custom serializer is provided (not void)
                    if (comptime custom_config.serializer != void) {
                        const Serializer = custom_config.serializer;
                        try jws.write(Serializer.serialize(self.value));
                    } else {
                        // Fallback to string if no custom serializer
                        try jws.write(@tagName(self.value));
                    }
                },
            }
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !T {
            _ = allocator;
            _ = options;

            switch (strategy) {
                .bare => {
                    // Parse integer value
                    const token = try source.next();
                    switch (token) {
                        .integer => |i| return @enumFromInt(@as(std.meta.Tag(T), @intCast(i))),
                        else => return error.UnexpectedToken,
                    }
                },
                .string => {
                    // Parse string and match to enum value
                    const token = try source.next();
                    const str = switch (token) {
                        .string => |s| s,
                        .allocated_string => |s| s,
                        else => return error.UnexpectedToken,
                    };

                    const enum_info = @typeInfo(T).@"enum";
                    inline for (enum_info.fields) |field| {
                        if (std.mem.eql(u8, str, field.name)) {
                            return @enumFromInt(field.value);
                        }
                    }
                    return error.UnknownField;
                },
                .custom => |custom_config| {
                    // Parse string and use custom deserializer
                    const token = try source.next();
                    const str = switch (token) {
                        .string => |s| s,
                        .allocated_string => |s| s,
                        else => return error.UnexpectedToken,
                    };

                    // Check if custom deserializer is provided (not void)
                    if (comptime custom_config.deserializer != void) {
                        const Deserializer = custom_config.deserializer;
                        return try Deserializer.deserialize(str);
                    } else {
                        // Fallback to string matching if no custom deserializer
                        const enum_info = @typeInfo(T).@"enum";
                        inline for (enum_info.fields) |field| {
                            if (std.mem.eql(u8, str, field.name)) {
                                return @enumFromInt(field.value);
                            }
                        }
                        return error.UnknownField;
                    }
                },
            }
        }
    };
}

/// Write a value to JSON WriteStream using its Mapper configuration
/// This allows custom serializers to recursively apply mappers to nested objects
///
/// Usage example:
/// ```zig
/// const PropertiesSerializer = struct {
/// Encode a value using its Mapper configuration
pub fn encodeWithMapper(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime MapperType: type,
    options: std.json.Stringify.Options,
) ![]const u8 {
    const Adapter = createAdapter(MapperType);
    const adapter = Adapter{ .value = value };
    return try std.json.Stringify.valueAlloc(allocator, adapter, options);
}

/// Decode a value using its Mapper configuration
/// Decode a value using its Mapper configuration
pub fn decodeWithMapper(
    allocator: std.mem.Allocator,
    comptime MapperType: type,
    json_str: []const u8,
    options: std.json.ParseOptions,
) !MapperType.TargetType {
    const Adapter = createAdapter(MapperType);

    var scanner = std.json.Scanner.initCompleteInput(allocator, json_str);
    defer scanner.deinit();

    return try Adapter.jsonParse(allocator, &scanner, options);
}

/// Decode a value using its Mapper configuration from an Io.Reader (streaming)
pub fn decodeWithReader(
    allocator: std.mem.Allocator,
    comptime MapperType: type,
    reader: *std.Io.Reader,
    options: std.json.ParseOptions,
) !MapperType.TargetType {
    const Adapter = createAdapter(MapperType);

    var json_reader = std.json.Reader.init(allocator, reader);
    defer json_reader.deinit();

    return try Adapter.jsonParse(allocator, &json_reader, options);
}
