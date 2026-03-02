//! JSON Root Codec - Explicit top-level array/map helpers.
//!
//! This module provides explicit root codecs for JSON top-level shapes.
//! It keeps Mapper focused on domain type mapping while enabling top-level
//! arrays and objects in a type-safe, explicit way.

const std = @import("std");

/// Root codec kind used by adapter dispatch.
pub const RootKind = enum {
    array_mapper,
    array_plain,
    map_mapper,
    map_plain,
    map_ordered_mapper,
    map_ordered_plain,
};

/// Hash map wrapper used by top-level JSON object codecs.
///
/// Keys are owned by this container and are freed by `deinit`.
/// Iteration order is not guaranteed.
pub fn RootMap(comptime V: type) type {
    return struct {
        const Self = @This();

        map: std.StringHashMapUnmanaged(V) = .empty,

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            self.map.deinit(allocator);
            self.* = undefined;
        }

        pub fn contains(self: *const Self, key: []const u8) bool {
            return self.map.contains(key);
        }

        pub fn get(self: *const Self, key: []const u8) ?V {
            return self.map.get(key);
        }

        pub fn iterator(self: *const Self) std.StringHashMapUnmanaged(V).Iterator {
            return self.map.iterator();
        }

        /// Insert using an owned key.
        ///
        /// If the key already exists, the existing key is preserved and the
        /// newly provided key is freed.
        pub fn putOwnedKey(self: *Self, allocator: std.mem.Allocator, owned_key: []const u8, value: V) !void {
            const gop = try self.map.getOrPut(allocator, owned_key);
            if (gop.found_existing) {
                allocator.free(owned_key);
            }
            gop.value_ptr.* = value;
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, key: []const u8, value: V) !void {
            const owned_key = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_key);
            try self.putOwnedKey(allocator, owned_key, value);
        }
    };
}

/// Ordered hash map wrapper used by top-level JSON object codecs.
///
/// Keys are owned by this container and are freed by `deinit`.
/// Iteration preserves insertion order.
pub fn OrderedRootMap(comptime V: type) type {
    return struct {
        const Self = @This();

        map: std.StringArrayHashMapUnmanaged(V) = .empty,

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            self.map.deinit(allocator);
            self.* = undefined;
        }

        pub fn contains(self: *const Self, key: []const u8) bool {
            return self.map.contains(key);
        }

        pub fn get(self: *const Self, key: []const u8) ?V {
            return self.map.get(key);
        }

        pub fn iterator(self: *const Self) std.StringArrayHashMapUnmanaged(V).Iterator {
            return self.map.iterator();
        }

        /// Insert using an owned key.
        ///
        /// If the key already exists, the existing key is preserved and the
        /// newly provided key is freed.
        pub fn putOwnedKey(self: *Self, allocator: std.mem.Allocator, owned_key: []const u8, value: V) !void {
            const gop = try self.map.getOrPut(allocator, owned_key);
            if (gop.found_existing) {
                allocator.free(owned_key);
            }
            gop.value_ptr.* = value;
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, key: []const u8, value: V) !void {
            const owned_key = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_key);
            try self.putOwnedKey(allocator, owned_key, value);
        }
    };
}

fn assertMapperLike(comptime MapperType: type) void {
    const info = @typeInfo(MapperType);
    const is_composite = info == .@"struct" or info == .@"union" or
        info == .@"enum" or info == .@"opaque";

    if (!is_composite or !@hasDecl(MapperType, "TargetType")) {
        @compileError("Root.array/map/mapOrdered expects a Mapper-like type with TargetType, got " ++ @typeName(MapperType));
    }
}

/// Factory for explicit top-level JSON codecs.
pub const Root = struct {
    /// Top-level JSON array where each element is decoded/encoded with Mapper.
    pub fn array(comptime ElementMapper: type) type {
        assertMapperLike(ElementMapper);
        return struct {
            pub const __izo_is_root_codec = true;
            pub const kind = RootKind.array_mapper;
            pub const TargetType = []const ElementMapper.TargetType;
            pub const ElementType = ElementMapper.TargetType;
            pub const ElementMapperType = ElementMapper;
        };
    }

    /// Top-level JSON array where each element uses plain std.json parsing.
    pub fn arrayOf(comptime ElemType: type) type {
        return struct {
            pub const __izo_is_root_codec = true;
            pub const kind = RootKind.array_plain;
            pub const TargetType = []const ElemType;
            pub const ElementType = ElemType;
        };
    }

    /// Top-level JSON object where each value is decoded/encoded with Mapper.
    pub fn map(comptime ValueMapper: type) type {
        assertMapperLike(ValueMapper);
        return struct {
            pub const __izo_is_root_codec = true;
            pub const kind = RootKind.map_mapper;
            pub const ValueType = ValueMapper.TargetType;
            pub const ValueMapperType = ValueMapper;
            pub const TargetType = RootMap(ValueType);
        };
    }

    /// Top-level JSON object where each value uses plain std.json parsing.
    pub fn mapOf(comptime ValType: type) type {
        return struct {
            pub const __izo_is_root_codec = true;
            pub const kind = RootKind.map_plain;
            pub const ValueType = ValType;
            pub const TargetType = RootMap(ValType);
        };
    }

    /// Top-level JSON object preserving insertion order, values use Mapper.
    pub fn mapOrdered(comptime ValueMapper: type) type {
        assertMapperLike(ValueMapper);
        return struct {
            pub const __izo_is_root_codec = true;
            pub const kind = RootKind.map_ordered_mapper;
            pub const ValueType = ValueMapper.TargetType;
            pub const ValueMapperType = ValueMapper;
            pub const TargetType = OrderedRootMap(ValueType);
        };
    }

    /// Top-level JSON object preserving insertion order, values parsed plainly.
    pub fn mapOrderedOf(comptime ValType: type) type {
        return struct {
            pub const __izo_is_root_codec = true;
            pub const kind = RootKind.map_ordered_plain;
            pub const ValueType = ValType;
            pub const TargetType = OrderedRootMap(ValType);
        };
    }
};

/// Returns true when a type is an izomorph JSON root codec.
pub fn isRootCodec(comptime CodecType: type) bool {
    const info = @typeInfo(CodecType);
    const is_composite = info == .@"struct" or info == .@"union" or
        info == .@"enum" or info == .@"opaque";

    if (!is_composite) return false;

    return @hasDecl(CodecType, "__izo_is_root_codec") and
        @hasDecl(CodecType, "kind") and
        @hasDecl(CodecType, "TargetType");
}
