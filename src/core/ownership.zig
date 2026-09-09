//! Cleanup for values produced by the core. Defaults and input views are not owned.
const std = @import("std");
const kind = @import("kind.zig");
const reflect = @import("../reflect.zig");
const opts = @import("options.zig");
const Allocator = std.mem.Allocator;

pub fn borrowedInput(d: anytype) ?[]const u8 {
    const D = switch (@typeInfo(@TypeOf(d))) {
        .pointer => |p| p.child,
        else => @TypeOf(d),
    };
    if (@hasField(D, "borrow_strings")) {
        if (d.borrow_strings) {
            if (@hasField(D, "scanner")) return d.scanner.input;
            if (@hasField(D, "input")) return d.input;
        }
    }
    if (@hasField(D, "parent")) return borrowedInput(d.parent);
    if (@hasField(D, "deser")) return borrowedInput(d.deser);
    return null;
}

pub fn free(comptime T: type, value: T, allocator: Allocator, comptime schema: anytype, input: ?[]const u8) void {
    freeDefault(T, value, allocator, schema, input, null);
}

fn freeDefault(comptime T: type, value: T, allocator: Allocator, comptime schema: anytype, input: ?[]const u8, comptime default: ?T) void {
    switch (comptime kind.typeKind(T)) {
        .string, .bytes, .slice => {
            if (default) |dv| {
                if (value.ptr == dv.ptr) return;
            }
            if (input) |src| {
                const p = @intFromPtr(value.ptr);
                if (p >= @intFromPtr(src.ptr) and p - @intFromPtr(src.ptr) <= src.len) return;
            }
            if (comptime kind.typeKind(T) == .slice) for (value) |elem| free(@typeInfo(T).pointer.child, elem, allocator, {}, input);
            allocator.free(value);
        },
        .pointer => {
            if (default) |dv| {
                if (value == dv) return;
            }
            free(@typeInfo(T).pointer.child, value.*, allocator, {}, input);
            allocator.destroy(value);
        },
        .array => {
            inline for (0..@typeInfo(T).array.len) |i| freeDefault(@typeInfo(T).array.child, value[i], allocator, {}, input, if (default) |dv| dv[i] else null);
        },
        .@"struct", .tuple => inline for (reflect.structFields(T)) |f| {
            const dv: ?f.type = comptime if (default) |d| @field(d, f.name) else if (opts.hasSerdeDefaultSchema(T, f.name, schema)) opts.getSerdeDefaultSchema(T, f.name, schema) else f.defaultValue();
            freeDefault(f.type, @field(value, f.name), allocator, {}, input, dv);
        },
        .optional => if (value) |v| freeDefault(@typeInfo(T).optional.child, v, allocator, schema, input, if (default) |dv| dv else null),
        .@"union" => inline for (reflect.unionFields(T)) |f| {
            if (value == @field(T, f.name) and f.type != void) freeDefault(f.type, @field(value, f.name), allocator, {}, input, if (default) |dv| (if (dv == @field(T, f.name)) @field(dv, f.name) else null) else null);
        },
        .map => {
            var mut = value;
            var it = mut.iterator();
            while (it.next()) |e| {
                free(kind.MapValueType(T), e.value_ptr.*, allocator, {}, input);
                if (kind.MapKeyType(T) == []const u8) allocator.free(e.key_ptr.*);
            }
            if (comptime kind.isMapManaged(T)) mut.deinit() else mut.deinit(allocator);
        },
        else => {},
    }
}
