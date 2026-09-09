const std = @import("std");
const compat = @import("compat");
const reflect = @import("../reflect.zig");
const kind_mod = @import("kind.zig");
const field_meta = @import("fields.zig");
pub const ownership = @import("ownership.zig");
const opts = @import("options.zig");

const Kind = kind_mod.Kind;
const Child = kind_mod.Child;
const typeKind = kind_mod.typeKind;
const Allocator = std.mem.Allocator;

pub fn deserialize(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    return deserializeSchema(T, allocator, deserializer, {}, map);
}

/// Deserialize with out-of-band type overrides.
/// Map: `.{ .{ Type, Adapter }, ... }` where Adapter has `fn deserialize(T, allocator, d) !T`.
pub fn deserializeWith(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    return deserializeSchema(T, allocator, deserializer, {}, map);
}

/// Deserialize with an external schema. Schema overrides T.serde.
/// Types with zerdeDeserialize bypass the schema.
pub fn deserializeSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime schema: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    if (comptime opts.hasCustomDeserializer(T)) {
        return T.zerdeDeserialize(T, allocator, deserializer);
    }

    if (comptime @TypeOf(map) != void) {
        if (comptime findOobAdapter(T, map)) |adapter| {
            return adapter.deserialize(T, allocator, deserializer);
        }
    }

    return switch (comptime typeKind(T)) {
        .bool => deserializer.deserializeBool(),
        .int => deserializer.deserializeInt(T),
        .float => deserializer.deserializeFloat(T),
        .string => deserializer.deserializeString(allocator),
        .void => deserializer.deserializeVoid(),
        .optional => deserializeOptional(Child(T), allocator, deserializer, map),
        .@"struct" => deserializeStructFieldsSchema(T, allocator, deserializer, schema, map),
        .@"enum" => deserializeEnumSchema(T, allocator, deserializer, schema),
        .@"union" => deserializeUnionDispatchSchema(T, allocator, deserializer, schema, map),
        .array => deserializeArray(T, allocator, deserializer, map),
        .slice => deserializeSlice(T, allocator, deserializer, map),
        .pointer => deserializePointerSchema(T, allocator, deserializer, map),
        .tuple => deserializeTupleSchema(T, allocator, deserializer, map),
        .bytes => {
            if (comptime @hasDecl(@TypeOf(deserializer.*), "deserializeBytes")) {
                return deserializer.deserializeBytes(allocator);
            }
            return deserializer.deserializeString(allocator);
        },
        .map => deserializeMapSchema(T, allocator, deserializer, map),
        else => @compileError("Cannot auto-deserialize: " ++ @typeName(T)),
    };
}

fn findOobAdapter(comptime T: type, comptime map: anytype) ?type {
    inline for (reflect.structFields(@TypeOf(map))) |field| {
        const entry = @field(map, field.name);
        if (entry[0] == T) return entry[1];
    }
    return null;
}

fn deserializeEnumSchema(comptime T: type, allocator: Allocator, deserializer: anytype, comptime schema: anytype) @TypeOf(deserializer.*).Error!T {
    if (comptime opts.getEnumReprSchema(T, schema) == .integer) {
        const tag_type = @typeInfo(T).@"enum".tag_type;
        const int_val = try deserializer.deserializeInt(tag_type);
        return compat.intToEnum(T, int_val) orelse
            return deserializer.raiseError(error.UnexpectedToken);
    }
    // No rename/alias: let the format handle it directly.
    if (comptime !opts.hasNameOverrides(T, schema)) {
        return deserializer.deserializeEnum(T);
    }
    // With rename/alias: read string and match in core.
    const name = try deserializer.deserializeString(allocator);
    defer ownership.free([]const u8, name, allocator, {}, ownership.borrowedInput(deserializer));
    inline for (reflect.enumFields(T)) |field| {
        if (opts.matchesDeserializeName(T, field.name, name, schema)) {
            return @enumFromInt(field.value);
        }
    }
    return deserializer.raiseError(error.UnexpectedToken);
}

fn deserializeArray(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    const info = @typeInfo(T).array;
    const child = info.child;
    var result: T = undefined;
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |elem| ownership.free(child, elem, allocator, {}, ownership.borrowedInput(deserializer));
    var seq = try deserializer.deserializeSeqAccess();
    for (0..info.len) |i| {
        result[i] = try nextElement(child, allocator, &seq, map) orelse return deserializer.raiseError(error.UnexpectedEof);
        initialized += 1;
    }
    // Consume the closing delimiter.
    if (try nextElement(child, allocator, &seq, map)) |extra| {
        ownership.free(child, extra, allocator, {}, ownership.borrowedInput(deserializer));
        return deserializer.raiseError(error.UnexpectedToken);
    }
    return result;
}

fn deserializePointerSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    const child = Child(T);
    const val = try deserializeSchema(child, allocator, deserializer, {}, map);
    errdefer ownership.free(child, val, allocator, {}, ownership.borrowedInput(deserializer));
    const ptr = try allocator.create(child);
    ptr.* = val;
    return ptr;
}

fn deserializeTupleSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    const fields = reflect.structFields(T);
    var result: T = undefined;
    var fields_seen = compat.staticBitSetEmpty(fields.len);
    errdefer {
        inline for (fields, 0..) |field, i| {
            if (fields_seen.isSet(i)) ownership.free(field.type, @field(result, field.name), allocator, {}, ownership.borrowedInput(deserializer));
        }
    }
    var seq = try deserializer.deserializeSeqAccess();
    inline for (fields, 0..) |field, i| {
        @field(result, field.name) = try nextElement(field.type, allocator, &seq, map) orelse
            return deserializer.raiseError(error.UnexpectedEof);
        fields_seen.set(i);
    }
    const Extra = if (fields.len > 0) fields[0].type else void;
    if (try nextElement(Extra, allocator, &seq, map)) |extra| {
        ownership.free(Extra, extra, allocator, {}, ownership.borrowedInput(deserializer));
        return deserializer.raiseError(error.UnexpectedToken);
    }
    return result;
}

/// Free an owned result. For external defaults use freeAllocatedSchema.
pub fn freeAllocated(comptime T: type, value: T, allocator: Allocator) void {
    ownership.free(T, value, allocator, {}, null);
}
pub fn freeAllocatedSchema(comptime T: type, value: T, allocator: Allocator, comptime schema: anytype) void {
    ownership.free(T, value, allocator, schema, null);
}

fn deserializeStructFieldsSchema(comptime T: type, allocator: Allocator, deserializer: anytype, comptime schema: anytype, comptime oob_map: anytype) @TypeOf(deserializer.*).Error!T {
    var map = try deserializer.deserializeStruct(T);
    return structFromMap(T, allocator, if (@typeInfo(@TypeOf(map)) == .pointer) map else &map, schema, oob_map, null);
}

fn structFromMap(comptime T: type, allocator: Allocator, map: anytype, comptime schema: anytype, comptime oob_map: anytype, comptime ignored: ?[]const u8) @TypeOf(map.*).Error!T {
    comptime field_meta.validate(T, schema, .deserialize);
    const fields = comptime field_meta.leaves(T, schema, .deserialize);
    var result: T = undefined;
    var seen = compat.staticBitSetEmpty(fields.len);
    errdefer inline for (fields, 0..) |F, i| {
        if (seen.isSet(i)) ownership.free(F.field.type, F.ptr(&result).*, allocator, {}, ownership.borrowedInput(map));
    };
    while (try map.nextKey(allocator)) |key| {
        defer freeKey(map, key, allocator);
        if (ignored) |name| {
            if (std.mem.eql(u8, key, name)) {
                try map.skipValue();
                continue;
            }
        }
        var matched = false;
        if (comptime fields.len <= 32) {
            inline for (fields, 0..) |F, i| {
                if (comptime opts.shouldSkipFieldSchema(F.Parent, F.field.name, .deserialize, F.schema)) continue;
                if (!matched and opts.matchesDeserializeName(F.Parent, F.field.name, key, F.schema)) {
                    if (seen.isSet(i)) return map.raiseError(error.DuplicateField);
                    if (comptime opts.hasFieldWithSchema(F.Parent, F.field.name, F.schema)) {
                        const With = comptime opts.getFieldWithSchema(F.Parent, F.field.name, F.schema);
                        const raw = try nextValue(With.WireType, allocator, map, oob_map);
                        // Allocating helpers create a distinct result; nonallocating helpers may borrow raw.
                        if (@hasDecl(With, "deserializeAlloc")) {
                            defer ownership.free(With.WireType, raw, allocator, {}, ownership.borrowedInput(map));
                            F.ptr(&result).* = With.deserializeAlloc(raw, allocator) catch |err| return map.raiseError(if (err == error.OutOfMemory) error.OutOfMemory else error.WithFailed);
                        } else F.ptr(&result).* = With.deserialize(raw);
                    } else F.ptr(&result).* = try nextValue(F.field.type, allocator, map, oob_map);
                    seen.set(i);
                    matched = true;
                }
            }
        } else if (field_meta.lookup(T, schema, key)) |i| {
            switch (i) {
                inline 0...fields.len - 1 => |index| try readStructField(fields[index], index, &result, &seen, allocator, map, oob_map),
                else => unreachable,
            }
            matched = true;
        }
        if (!matched) {
            if (comptime opts.denyUnknownFieldsSchema(T, schema)) return map.raiseError(error.UnknownField);
            try map.skipValue();
        }
    }
    // Defaults are assigned only after input parsing. They are not owned or received fields.
    inline for (fields, 0..) |F, i| {
        if (!seen.isSet(i)) {
            if (comptime F.defaultValue()) |dv| {
                F.ptr(&result).* = dv;
            } else if (@typeInfo(F.field.type) == .optional) {
                F.ptr(&result).* = null;
            } else return map.raiseError(error.MissingField);
        }
    }
    return result;
}

inline fn readStructField(comptime F: type, comptime i: usize, result: anytype, seen: anytype, allocator: Allocator, map: anytype, comptime oob_map: anytype) @TypeOf(map.*).Error!void {
    if (seen.isSet(i)) return map.raiseError(error.DuplicateField);
    if (comptime opts.hasFieldWithSchema(F.Parent, F.field.name, F.schema)) {
        const With = comptime opts.getFieldWithSchema(F.Parent, F.field.name, F.schema);
        const raw = try nextValue(With.WireType, allocator, map, oob_map);
        // Allocating helpers create a distinct result; nonallocating helpers may borrow raw.
        if (@hasDecl(With, "deserializeAlloc")) {
            defer ownership.free(With.WireType, raw, allocator, {}, ownership.borrowedInput(map));
            F.ptr(result).* = With.deserializeAlloc(raw, allocator) catch |err| return map.raiseError(if (err == error.OutOfMemory) error.OutOfMemory else error.WithFailed);
        } else F.ptr(result).* = With.deserialize(raw);
    } else F.ptr(result).* = try nextValue(F.field.type, allocator, map, oob_map);
    seen.set(i);
}

pub fn freeKey(map: anytype, key: []const u8, allocator: Allocator) void {
    const M = switch (@typeInfo(@TypeOf(map))) {
        .pointer => |p| p.child,
        else => @TypeOf(map),
    };
    if (@hasDecl(M, "freeKey")) map.freeKey(key, allocator);
}

// Preserve adapters when crossing a format's generic access API.
fn Adapted(comptime T: type, comptime map: anytype) type {
    return struct {
        value: T,
        pub fn zerdeDeserialize(comptime _: type, allocator: Allocator, d: anytype) @TypeOf(d.*).Error!@This() {
            return .{ .value = try deserializeSchema(T, allocator, d, {}, map) };
        }
    };
}
fn hasMap(comptime map: anytype) bool {
    return @TypeOf(map) != void and reflect.structFields(@TypeOf(map)).len != 0;
}
fn nextValue(comptime T: type, allocator: Allocator, access: anytype, comptime map: anytype) @TypeOf(access.*).Error!T {
    if (comptime hasMap(map)) return (try access.nextValue(Adapted(T, map), allocator)).value;
    return access.nextValue(T, allocator);
}
fn nextElement(comptime T: type, allocator: Allocator, access: anytype, comptime map: anytype) @TypeOf(access.*).Error!?T {
    if (comptime hasMap(map)) {
        if (try access.nextElement(Adapted(T, map), allocator)) |v| return v.value;
        return null;
    }
    return access.nextElement(T, allocator);
}
fn deserializeOptional(comptime T: type, allocator: Allocator, d: anytype, comptime map: anytype) @TypeOf(d.*).Error!?T {
    if (comptime hasMap(map)) {
        if (try d.deserializeOptional(Adapted(T, map), allocator)) |v| return v.value;
        return null;
    }
    return d.deserializeOptional(T, allocator);
}
fn deserializeSlice(comptime T: type, allocator: Allocator, d: anytype, comptime map: anytype) @TypeOf(d.*).Error!T {
    const C = Child(T);
    var seq = try d.deserializeSeqAccess();
    var items: std.ArrayList(C) = .empty;
    errdefer {
        for (items.items) |v| ownership.free(C, v, allocator, {}, ownership.borrowedInput(d));
        items.deinit(allocator);
    }
    if (@hasField(@TypeOf(seq), "remaining")) {
        // Length prefixes are hints until the input is validated. Bound the
        // eager allocation so truncated hostile input cannot reserve gigabytes.
        const max_hint = @max(1, 64 * 1024 / @max(1, @sizeOf(C)));
        try items.ensureTotalCapacityPrecise(allocator, @min(seq.remaining, max_hint));
    } else if (@hasField(@TypeOf(seq), "items")) {
        try items.ensureTotalCapacityPrecise(allocator, seq.items.len);
    }
    while (try nextElement(C, allocator, &seq, map)) |v| {
        errdefer ownership.free(C, v, allocator, {}, ownership.borrowedInput(d));
        try items.append(allocator, v);
    }
    return items.toOwnedSlice(allocator);
}

fn deserializeUnionDispatchSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime schema: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    const tag_style = comptime opts.getUnionTagSchema(T, schema);
    return switch (tag_style) {
        .external => if (comptime opts.hasNameOverrides(T, schema) or hasMap(map))
            deserializeUnionExternalSchema(T, allocator, deserializer, schema, map)
        else
            deserializer.deserializeUnion(T, allocator),
        .internal => deserializeUnionInternalSchema(T, allocator, deserializer, schema, map),
        .adjacent => deserializeUnionAdjacentSchema(T, allocator, deserializer, schema, map),
        .untagged => deserializeUnionUntaggedSchema(T, allocator, deserializer, map),
    };
}

/// External union deser with rename/alias. Tries bare string first (void
/// variants), then {"variant": payload} form. Uses save/restore like untagged.
fn deserializeUnionExternalSchema(comptime T: type, allocator: Allocator, d: anytype, comptime schema: anytype, comptime oob_map: anytype) @TypeOf(d.*).Error!T {
    const saved = d.*;
    if (d.deserializeString(allocator)) |name| {
        defer ownership.free([]const u8, name, allocator, {}, ownership.borrowedInput(d));
        inline for (reflect.unionFields(T)) |f| {
            if (f.type == void and opts.matchesDeserializeName(T, f.name, name, schema)) return @unionInit(T, f.name, {});
        }
        d.* = saved;
    } else |err| {
        if (err == error.OutOfMemory) return d.raiseError(error.OutOfMemory);
        d.* = saved;
    }
    var access = try d.deserializeStruct(T);
    const key = (try access.nextKey(allocator)) orelse return d.raiseError(error.MissingField);
    defer freeKey(&access, key, allocator);
    inline for (reflect.unionFields(T)) |f| {
        if (opts.matchesDeserializeName(T, f.name, key, schema)) {
            const payload = if (f.type == void) blk: {
                try access.skipValue();
                break :blk {};
            } else try nextValue(f.type, allocator, &access, oob_map);
            errdefer ownership.free(f.type, payload, allocator, {}, ownership.borrowedInput(d));
            if (try access.nextKey(allocator)) |extra| {
                freeKey(&access, extra, allocator);
                return d.raiseError(error.UnexpectedToken);
            }
            return @unionInit(T, f.name, payload);
        }
    }
    return d.raiseError(error.UnexpectedToken);
}

// Scan once for the discriminator, then replay the input or tree through the
// same field machinery. No intermediate DOM is required.
fn unionTag(comptime T: type, allocator: Allocator, d: anytype, comptime schema: anytype) @TypeOf(d.*).Error![]const u8 {
    var access = try d.deserializeStruct(T);
    var name: ?[]const u8 = null;
    errdefer if (name) |n| ownership.free([]const u8, n, allocator, {}, ownership.borrowedInput(d));
    while (try access.nextKey(allocator)) |key| {
        defer freeKey(&access, key, allocator);
        if (std.mem.eql(u8, key, comptime opts.getTagFieldSchema(T, schema))) {
            if (name != null) return d.raiseError(error.DuplicateField);
            name = try access.nextValue([]const u8, allocator);
        } else try access.skipValue();
    }
    return name orelse d.raiseError(error.MissingField);
}
fn WithoutTagMap(comptime A: type, comptime D: type, comptime tag_key: []const u8) type {
    return struct {
        base: A,
        parent: *D,
        const Self = @This();
        pub const Error = D.Error;
        fn access(self: *Self) if (@typeInfo(A) == .pointer) A else *A {
            if (comptime @typeInfo(A) == .pointer) return self.base;
            return &self.base;
        }
        pub fn nextKey(self: *Self, allocator: Allocator) Error!?[]const u8 {
            while (try self.access().nextKey(allocator)) |key| {
                if (!std.mem.eql(u8, key, tag_key)) return key;
                defer releaseKey(self.access(), key, allocator);
                try self.access().skipValue();
            }
            return null;
        }
        pub fn nextValue(self: *Self, comptime T: type, allocator: Allocator) Error!T {
            return self.access().nextValue(T, allocator);
        }
        pub fn skipValue(self: *Self) Error!void {
            return self.access().skipValue();
        }
        pub fn freeKey(self: *Self, key: []const u8, allocator: Allocator) void {
            releaseKey(self.access(), key, allocator);
        }
        pub fn raiseError(self: *Self, err: anyerror) Error {
            return self.parent.raiseError(err);
        }
    };
}
const releaseKey = freeKey;
fn WithoutTagDeserializer(comptime D: type, comptime tag_key: []const u8) type {
    return struct {
        parent: *D,
        const Self = @This();
        pub const Error = D.Error;
        pub fn deserializeStruct(self: *Self, comptime T: type) Error!WithoutTagMap(@typeInfo(@TypeOf(@as(*D, undefined).deserializeStruct(T))).error_union.payload, D, tag_key) {
            return .{ .base = try self.parent.deserializeStruct(T), .parent = self.parent };
        }
        pub fn raiseError(self: *Self, err: anyerror) Error {
            return self.parent.raiseError(err);
        }
    };
}

fn deserializeUnionInternalSchema(comptime T: type, allocator: Allocator, d: anytype, comptime schema: anytype, comptime oob_map: anytype) @TypeOf(d.*).Error!T {
    const saved = d.*;
    const name = try unionTag(T, allocator, d, schema);
    defer ownership.free([]const u8, name, allocator, {}, ownership.borrowedInput(d));
    inline for (reflect.unionFields(T)) |f| {
        if (opts.matchesDeserializeName(T, f.name, name, schema)) {
            if (f.type == void) return @unionInit(T, f.name, {});
            d.* = saved;
            if (comptime opts.hasCustomDeserializer(f.type) or
                (@TypeOf(oob_map) != void and findOobAdapter(f.type, oob_map) != null))
            {
                var filtered = WithoutTagDeserializer(@TypeOf(d.*), opts.getTagFieldSchema(T, schema)){ .parent = d };
                return @unionInit(T, f.name, try deserializeSchema(f.type, allocator, &filtered, {}, oob_map));
            }
            var access = try d.deserializeStruct(f.type);
            const payload = try structFromMap(f.type, allocator, &access, {}, oob_map, opts.getTagFieldSchema(T, schema));
            return @unionInit(T, f.name, payload);
        }
    }
    return d.raiseError(error.UnexpectedToken);
}
fn deserializeUnionAdjacentSchema(comptime T: type, allocator: Allocator, d: anytype, comptime schema: anytype, comptime oob_map: anytype) @TypeOf(d.*).Error!T {
    const saved = d.*;
    const name = try unionTag(T, allocator, d, schema);
    defer ownership.free([]const u8, name, allocator, {}, ownership.borrowedInput(d));
    inline for (reflect.unionFields(T)) |f| {
        if (opts.matchesDeserializeName(T, f.name, name, schema)) {
            d.* = saved;
            var access = try d.deserializeStruct(T);
            var payload: ?f.type = null;
            errdefer if (payload) |v| ownership.free(f.type, v, allocator, {}, ownership.borrowedInput(d));
            while (try access.nextKey(allocator)) |key| {
                defer freeKey(&access, key, allocator);
                if (std.mem.eql(u8, key, comptime opts.getContentFieldSchema(T, schema))) {
                    if (payload != null) return d.raiseError(error.DuplicateField);
                    if (f.type == void) {
                        try access.skipValue();
                        payload = {};
                    } else payload = try nextValue(f.type, allocator, &access, oob_map);
                } else try access.skipValue();
            }
            if (f.type == void) return @unionInit(T, f.name, {});
            return @unionInit(T, f.name, payload orelse return d.raiseError(error.MissingField));
        }
    }
    return d.raiseError(error.UnexpectedToken);
}

fn deserializeMapSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime oob_map: anytype,
) @TypeOf(deserializer.*).Error!T {
    const K = kind_mod.MapKeyType(T);
    const V = kind_mod.MapValueType(T);
    const managed = comptime kind_mod.isMapManaged(T);

    var result: T = if (managed) T.init(allocator) else .{};
    errdefer ownership.free(T, result, allocator, {}, ownership.borrowedInput(deserializer));

    var map = try deserializer.deserializeStruct(T);

    while (try map.nextKey(allocator)) |key| {
        defer freeKey(&map, key, allocator);
        const k: K = if (K == []const u8) blk: {
            const owned = allocator.alloc(u8, key.len) catch return deserializer.raiseError(error.OutOfMemory);
            @memcpy(owned, key);
            break :blk owned;
        } else if (@typeInfo(K) == .int)
            std.fmt.parseInt(K, key, 10) catch return deserializer.raiseError(error.InvalidNumber)
        else
            @compileError("Unsupported map key type: " ++ @typeName(K));

        const v = nextValue(V, allocator, &map, oob_map) catch |err| {
            if (K == []const u8) allocator.free(k);
            return err;
        };

        errdefer {
            if (K == []const u8) allocator.free(k);
            ownership.free(V, v, allocator, {}, ownership.borrowedInput(deserializer));
        }
        const entry = if (managed) try result.getOrPut(k) else try result.getOrPut(allocator, k);
        if (entry.found_existing) {
            if (K == []const u8) allocator.free(k);
            ownership.free(V, entry.value_ptr.*, allocator, {}, ownership.borrowedInput(deserializer));
        }
        entry.value_ptr.* = v;
    }

    return result;
}

fn deserializeUnionUntaggedSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    inline for (reflect.unionFields(T)) |field| {
        const saved = deserializer.*;
        if (field.type == void) {
            if (deserializer.deserializeVoid()) {
                return @unionInit(T, field.name, {});
            } else |err| {
                if (err == error.OutOfMemory) return deserializer.raiseError(error.OutOfMemory);
                deserializer.* = saved;
            }
        } else {
            if (deserializeSchema(field.type, allocator, deserializer, {}, map)) |payload| {
                return @unionInit(T, field.name, payload);
            } else |err| {
                if (err == error.OutOfMemory) return deserializer.raiseError(error.OutOfMemory);
                deserializer.* = saved;
            }
        }
    }

    return deserializer.raiseError(error.UnexpectedToken);
}

const testing = std.testing;

const MockMapAccess = struct {
    keys: []const []const u8,
    values: []const MockValue,
    pos: usize = 0,

    pub const Error = error{ UnknownField, DuplicateField, MissingField, UnexpectedEof, OutOfMemory, WithFailed, WrongType };

    pub fn nextKey(self: *MockMapAccess, _: Allocator) Error!?[]const u8 {
        if (self.pos >= self.keys.len) return null;
        return self.keys[self.pos];
    }

    pub fn nextValue(self: *MockMapAccess, comptime T: type, allocator: Allocator) Error!T {
        if (self.pos >= self.values.len) return error.UnexpectedEof;
        const v = self.values[self.pos];
        self.pos += 1;
        return switch (v) {
            .int => |i| if (T == i32 or T == u32 or T == u64 or T == i64) @intCast(i) else error.WrongType,
            .string => |s| if (T == []const u8) try allocator.dupe(u8, s) else error.WrongType,
            .boolean => |b| if (T == bool) b else error.WrongType,
            .float => |f| if (T == f64 or T == f32) @floatCast(f) else error.WrongType,
        };
    }

    pub fn skipValue(self: *MockMapAccess) Error!void {
        self.pos += 1;
    }

    pub fn raiseError(_: *MockMapAccess, err: anyerror) Error {
        return switch (err) {
            error.UnknownField => error.UnknownField,
            error.MissingField => error.MissingField,
            error.DuplicateField => error.DuplicateField,
            error.WithFailed => error.WithFailed,
            else => error.WrongType,
        };
    }
};

const MockValue = union(enum) {
    int: i64,
    string: []const u8,
    boolean: bool,
    float: f64,
};

const MockDeserializer = struct {
    map: MockMapAccess,

    pub const Error = MockMapAccess.Error;

    pub fn deserializeStruct(self: *MockDeserializer, comptime _: type) Error!*MockMapAccess {
        return &self.map;
    }

    pub fn deserializeBool(_: *MockDeserializer) Error!bool {
        return true;
    }

    pub fn deserializeInt(_: *MockDeserializer, comptime T: type) Error!T {
        return 0;
    }

    pub fn deserializeFloat(_: *MockDeserializer, comptime T: type) Error!T {
        return 0;
    }

    pub fn deserializeString(_: *MockDeserializer, _: Allocator) Error![]const u8 {
        return "";
    }

    pub fn deserializeVoid(_: *MockDeserializer) Error!void {}

    pub fn deserializeOptional(_: *MockDeserializer, comptime _: type, _: Allocator) Error!void {}

    pub fn deserializeEnum(_: *MockDeserializer, comptime T: type) Error!T {
        return @enumFromInt(0);
    }

    pub fn deserializeUnion(_: *MockDeserializer, comptime _: type, _: Allocator) Error!void {}

    pub fn deserializeSeq(_: *MockDeserializer, comptime _: type, _: Allocator) Error!void {}

    pub fn raiseError(_: *MockDeserializer, err: anyerror) Error {
        return switch (err) {
            error.UnknownField => error.UnknownField,
            error.MissingField => error.MissingField,
            error.DuplicateField => error.DuplicateField,
            error.WithFailed => error.WithFailed,
            else => error.WrongType,
        };
    }
};

test "deserialize struct basic" {
    const Point = struct { x: i32, y: i32 };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "x", "y" },
            .values = &.{ .{ .int = 10 }, .{ .int = 20 } },
        },
    };
    const point = try deserialize(Point, testing.allocator, &deser, .{});
    try testing.expectEqual(@as(i32, 10), point.x);
    try testing.expectEqual(@as(i32, 20), point.y);
}

test "deserialize struct with optional missing" {
    const Opt = struct { a: i32, b: ?i32 };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{"a"},
            .values = &.{.{ .int = 5 }},
        },
    };
    const val = try deserialize(Opt, testing.allocator, &deser, .{});
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(?i32, null), val.b);
}

test "deserialize struct missing required field" {
    const Req = struct { a: i32, b: i32 };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{"a"},
            .values = &.{.{ .int = 1 }},
        },
    };
    const result = deserialize(Req, testing.allocator, &deser, .{});
    try testing.expectError(error.MissingField, result);
}

test "deserialize struct with default" {
    const Def = struct {
        a: i32,
        b: i32 = 99,
    };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{"a"},
            .values = &.{.{ .int = 1 }},
        },
    };
    const val = try deserialize(Def, testing.allocator, &deser, .{});
    try testing.expectEqual(@as(i32, 1), val.a);
    try testing.expectEqual(@as(i32, 99), val.b);
}

test "deserialize flatten + nested .with" {
    const B64 = struct {
        data: []const u8,

        pub const serde = .{
            .with = .{
                .data = @import("../helpers/base64.zig").Base64,
            },
        };
    };

    const Base64 = struct {
        b64: B64,

        pub const serde = .{
            .flatten = &[_][]const u8{"b64"},
        };
    };

    const input_base64 = "VGVzdCBwYXNzZWQ/";
    const expected = "Test passed?";

    var deser = MockDeserializer{
        .map = .{
            .keys = &.{"data"},
            .values = &.{.{ .string = input_base64 }},
        },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const val = try deserialize(Base64, arena.allocator(), &deser, .{});

    try testing.expectEqualStrings(expected, val.b64.data);
}

test "deserialize flatten + nested .with maps allocating helper errors" {
    const B64 = struct {
        data: []const u8,

        pub const serde = .{
            .with = .{
                .data = @import("../helpers/base64.zig").Base64,
            },
        };
    };

    const Base64 = struct {
        b64: B64,

        pub const serde = .{
            .flatten = &[_][]const u8{"b64"},
        };
    };

    var deser = MockDeserializer{
        .map = .{
            .keys = &.{"data"},
            .values = &.{.{ .string = "not base64" }},
        },
    };

    try testing.expectError(error.WithFailed, deserialize(Base64, testing.allocator, &deser, .{}));
}

test "deserialize struct with rename" {
    const User = struct {
        id: u64,
        first_name: []const u8,

        pub const serde = .{
            .rename = .{ .id = "user_id" },
            .rename_all = opts.NamingConvention.camel_case,
        };
    };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "user_id", "firstName" },
            .values = &.{ .{ .int = 42 }, .{ .string = "Bob" } },
        },
    };
    const val = try deserialize(User, testing.allocator, &deser, .{});
    try testing.expectEqual(@as(u64, 42), val.id);
    defer testing.allocator.free(val.first_name);
    try testing.expectEqualStrings("Bob", val.first_name);
}

test "deserialize struct deny unknown fields" {
    const Strict = struct {
        x: i32,
        pub const serde = .{
            .deny_unknown_fields = true,
        };
    };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "x", "unknown" },
            .values = &.{ .{ .int = 1 }, .{ .int = 2 } },
        },
    };
    const result = deserialize(Strict, testing.allocator, &deser, .{});
    try testing.expectError(error.UnknownField, result);
}

test "deserialize struct ignores unknown fields by default" {
    const Loose = struct { x: i32 };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "x", "extra" },
            .values = &.{ .{ .int = 5 }, .{ .int = 99 } },
        },
    };
    const val = try deserialize(Loose, testing.allocator, &deser, .{});
    try testing.expectEqual(@as(i32, 5), val.x);
}

// Schema-based deserialization tests.

test "deserializeSchema with rename on plain struct" {
    const Point = struct { x: i32, y: i32 };
    const schema = .{ .rename = .{ .x = "X", .y = "Y" } };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "X", "Y" },
            .values = &.{ .{ .int = 10 }, .{ .int = 20 } },
        },
    };
    const val = try deserializeSchema(Point, testing.allocator, &deser, schema, .{});
    try testing.expectEqual(@as(i32, 10), val.x);
    try testing.expectEqual(@as(i32, 20), val.y);
}

test "deserializeSchema with deny_unknown_fields via schema" {
    const Plain = struct { x: i32 };
    const schema = .{ .deny_unknown_fields = true };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "x", "extra" },
            .values = &.{ .{ .int = 1 }, .{ .int = 2 } },
        },
    };
    const result = deserializeSchema(Plain, testing.allocator, &deser, schema, .{});
    try testing.expectError(error.UnknownField, result);
}

test "deserializeSchema with skip via schema" {
    const S = struct { a: i32, b: i32 = 0 };
    const schema = .{ .skip = .{ .b = opts.SkipMode.always } };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{"a"},
            .values = &.{.{ .int = 5 }},
        },
    };
    const val = try deserializeSchema(S, testing.allocator, &deser, schema, .{});
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(i32, 0), val.b);
}

// Out-of-band (OOB) customization tests.

test "deserializeWith: custom adapter compiles" {
    const Wrapper = struct { inner: u32 };

    const WrapperAdapter = struct {
        pub fn deserialize(comptime _: type, _: Allocator, d: anytype) @TypeOf(d.*).Error!Wrapper {
            const val = try d.deserializeInt(u32);
            return .{ .inner = val };
        }
    };

    // Verify the adapter type is valid for the map pattern.
    const map = .{.{ Wrapper, WrapperAdapter }};
    _ = map;
}
