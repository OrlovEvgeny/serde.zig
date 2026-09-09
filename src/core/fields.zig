//! Compile-time expansion of struct fields shared by serialization and parsing.
const std = @import("std");
const reflect = @import("../reflect.zig");
const opts = @import("options.zig");

pub fn leaves(comptime T: type, comptime schema: anytype, comptime dir: opts.Direction) []const type {
    return comptime expand(T, schema, dir, &.{}, T, schema);
}

fn expand(comptime T: type, comptime schema: anytype, comptime dir: opts.Direction, comptime path: []const []const u8, comptime Root: type, comptime root_schema: anytype) []const type {
    @setEvalBranchQuota(100_000);
    var result: []const type = &.{};
    for (reflect.structFields(T)) |f| {
        const next = path ++ &[_][]const u8{f.name};
        const head = if (opts.isFlattenedFieldSchema(T, f.name, schema) and !opts.shouldSkipFieldSchema(T, f.name, dir, schema))
            expand(f.type, {}, dir, next, Root, root_schema)
        else
            &[_]type{Leaf(T, schema, f, next, Root, root_schema)};
        result = result ++ head;
    }
    return result;
}

fn Leaf(comptime P: type, comptime s: anytype, comptime f: anytype, comptime p: []const []const u8, comptime Root: type, comptime root_schema: anytype) type {
    return struct {
        pub const Parent = P;
        pub const schema = s;
        pub const field = f;
        pub const path = p;
        pub fn defaultValue() ?f.type {
            return comptime defaultAtPath(Root, root_schema, p, null);
        }
        pub fn get(value: anytype) f.type {
            return fieldValue(value, p);
        }
        pub fn ptr(value: anytype) *f.type {
            return fieldPtr(value, p);
        }
    };
}
fn defaultAtPath(comptime T: type, comptime schema: anytype, comptime path: []const []const u8, comptime inherited: ?T) ?@TypeOf(fieldValue(@as(T, undefined), path)) {
    if (path.len == 0) return inherited;
    inline for (reflect.structFields(T)) |f| {
        if (comptime std.mem.eql(u8, f.name, path[0])) {
            const value: ?f.type = comptime if (inherited) |v| @field(v, f.name) else if (opts.hasSerdeDefaultSchema(T, f.name, schema)) opts.getSerdeDefaultSchema(T, f.name, schema) else f.defaultValue();
            return defaultAtPath(f.type, {}, path[1..], value);
        }
    }
    unreachable;
}
fn fieldValue(value: anytype, comptime path: []const []const u8) blk: {
    if (path.len == 0) break :blk @TypeOf(value);
    break :blk @TypeOf(fieldValue(@field(value, path[0]), path[1..]));
} {
    if (path.len == 0) return value;
    return fieldValue(@field(value, path[0]), path[1..]);
}
fn fieldPtr(value: anytype, comptime path: []const []const u8) blk: {
    if (path.len == 0) break :blk @TypeOf(value);
    break :blk @TypeOf(fieldPtr(&@field(value.*, path[0]), path[1..]));
} {
    if (path.len == 0) return value;
    return fieldPtr(&@field(value.*, path[0]), path[1..]);
}

pub fn validate(comptime T: type, comptime schema: anytype, comptime dir: opts.Direction) void {
    @setEvalBranchQuota(100_000);
    const fs = leaves(T, schema, dir);
    for (fs, 0..) |A, i| {
        if (opts.shouldSkipFieldSchema(A.Parent, A.field.name, dir, A.schema)) continue;
        for (fs, 0..) |B, j| {
            if (j >= i) continue;
            if (opts.shouldSkipFieldSchema(B.Parent, B.field.name, dir, B.schema)) continue;
            const an = opts.wireFieldNameForDir(A.Parent, A.field.name, A.schema, dir);
            const bn = opts.wireFieldNameForDir(B.Parent, B.field.name, B.schema, dir);
            if (std.mem.eql(u8, an, bn)) @compileError("Ambiguous serde field name: " ++ an);
            if (dir == .deserialize) {
                for (opts.getFieldAliases(A.Parent, A.field.name, A.schema)) |a| {
                    if (opts.matchesDeserializeName(B.Parent, B.field.name, a, B.schema)) @compileError("Ambiguous serde alias: " ++ a);
                }
                for (opts.getFieldAliases(B.Parent, B.field.name, B.schema)) |b| {
                    if (std.mem.eql(u8, an, b)) @compileError("Ambiguous serde alias: " ++ b);
                }
            }
        }
    }
}

/// Wire names and aliases share a single field index, including flattened paths.
pub fn lookup(comptime T: type, comptime schema: anytype, key: []const u8) ?usize {
    const fs = comptime leaves(T, schema, .deserialize);
    // Measurements favor direct comparisons through 32 fields.
    if (comptime fs.len <= 32) {
        inline for (fs, 0..) |F, i| {
            if (comptime opts.shouldSkipFieldSchema(F.Parent, F.field.name, .deserialize, F.schema)) continue;
            if (opts.matchesDeserializeName(F.Parent, F.field.name, key, F.schema)) return i;
        }
        return null;
    }
    const table = comptime blk: {
        @setEvalBranchQuota(100_000);
        var count: usize = 0;
        for (fs) |F| {
            if (opts.shouldSkipFieldSchema(F.Parent, F.field.name, .deserialize, F.schema)) continue;
            count += 1 + opts.getFieldAliases(F.Parent, F.field.name, F.schema).len;
        }
        const capacity = std.math.ceilPowerOfTwo(usize, @max(2, count * 2)) catch unreachable;
        var entries: [capacity]?struct { name: []const u8, index: usize } = @splat(null);
        for (fs, 0..) |F, i| {
            if (opts.shouldSkipFieldSchema(F.Parent, F.field.name, .deserialize, F.schema)) continue;
            const primary = opts.wireFieldNameForDir(F.Parent, F.field.name, F.schema, .deserialize);
            var slot = std.hash.Fnv1a_64.hash(primary) & (capacity - 1);
            while (entries[slot] != null) slot = (slot + 1) & (capacity - 1);
            entries[slot] = .{ .name = primary, .index = i };
            for (opts.getFieldAliases(F.Parent, F.field.name, F.schema)) |alias| {
                slot = std.hash.Fnv1a_64.hash(alias) & (capacity - 1);
                while (entries[slot] != null) slot = (slot + 1) & (capacity - 1);
                entries[slot] = .{ .name = alias, .index = i };
            }
        }
        break :blk entries;
    };
    var slot = std.hash.Fnv1a_64.hash(key) & (table.len - 1);
    while (table[slot]) |entry| {
        if (std.mem.eql(u8, entry.name, key)) return entry.index;
        slot = (slot + 1) & (table.len - 1);
    }
    return null;
}
