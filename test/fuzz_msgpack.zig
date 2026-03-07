const std = @import("std");
const serde = @import("serde");

const Address = struct {
    city: []const u8,
    zip: ?[]const u8 = null,
};

const Role = enum { admin, user, guest };

const Action = union(enum) {
    login: void,
    update: struct { field: []const u8, value: []const u8 },
};

const FuzzTarget = struct {
    id: u64,
    name: []const u8,
    email: ?[]const u8 = null,
    age: ?i32 = null,
    score: f64,
    active: bool,
    role: Role,
    address: Address,
    tags: []const []const u8 = &.{},
    history: []const Action = &.{},
    counts: []const i32 = &.{},
    nested: ?Address = null,
};

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.c) c_int {
    const input = data[0..size];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = serde.msgpack.fromSlice(FuzzTarget, a, input) catch {};
    _ = serde.msgpack.fromSlice(bool, a, input) catch {};
    _ = serde.msgpack.fromSlice(i32, a, input) catch {};
    _ = serde.msgpack.fromSlice([]const i32, a, input) catch {};
    _ = serde.msgpack.fromSlice(Address, a, input) catch {};

    return 0;
}
