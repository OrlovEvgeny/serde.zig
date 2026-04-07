const std = @import("std");
const serde = @import("serde");

/// Wraps a u64 that is transmitted as a JSON/TOML string on the wire.
/// Common for APIs where IDs exceed JavaScript's safe integer range (>2^53).
const StringId = struct {
    value: u64,

    pub fn zerdeSerialize(self: @This(), serializer: anytype) !void {
        var buf: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{self.value}) catch unreachable;
        try serializer.serializeString(s);
    }

    pub fn zerdeDeserialize(
        comptime _: type,
        allocator: std.mem.Allocator,
        deserializer: anytype,
    ) @TypeOf(deserializer.*).Error!@This() {
        const str = try deserializer.deserializeString(allocator);
        defer allocator.free(str);
        return .{
            .value = std.fmt.parseInt(u64, str, 10) catch return error.InvalidNumber,
        };
    }
};

/// Wraps a byte slice that is transmitted as a hex-encoded string.
const HexBytes = struct {
    data: []const u8,

    pub fn zerdeSerialize(self: @This(), serializer: anytype) !void {
        var buf: [1024]u8 = undefined;
        if (self.data.len * 2 > buf.len) return error.OutOfMemory;
        for (self.data, 0..) |byte, i| {
            _ = std.fmt.bufPrint(buf[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
        }
        try serializer.serializeString(buf[0 .. self.data.len * 2]);
    }

    pub fn zerdeDeserialize(
        comptime _: type,
        allocator: std.mem.Allocator,
        deserializer: anytype,
    ) @TypeOf(deserializer.*).Error!@This() {
        const str = try deserializer.deserializeString(allocator);
        defer allocator.free(str);
        if (str.len % 2 != 0) return error.InvalidNumber;
        const result = try allocator.alloc(u8, str.len / 2);
        for (0..result.len) |i| {
            result[i] = std.fmt.parseInt(u8, str[i * 2 ..][0..2], 16) catch return error.InvalidNumber;
        }
        return .{ .data = result };
    }
};

const Order = struct {
    id: StringId,
    amount: f64,
    label: []const u8,
};

const Signature = struct {
    payload: HexBytes,
    algorithm: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // --- StringId: u64 <-> JSON string ---
    const order = Order{
        .id = .{ .value = 9223372036854775807 },
        .amount = 42.50,
        .label = "widgets",
    };
    const json = try serde.json.toSlice(allocator, order);
    defer allocator.free(json);
    std.debug.print("Order -> JSON:   {s}\n", .{json});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed_order = try serde.json.fromSlice(Order, arena.allocator(), json);
    std.debug.print("Order <- JSON:   id={}, amount={d}, label=\"{s}\"\n\n", .{
        parsed_order.id.value,
        parsed_order.amount,
        parsed_order.label,
    });

    // --- HexBytes: []const u8 <-> hex string ---
    const sig = Signature{
        .payload = .{ .data = &.{ 0xDE, 0xAD, 0xBE, 0xEF } },
        .algorithm = "sha256",
    };
    const sig_json = try serde.json.toSlice(allocator, sig);
    defer allocator.free(sig_json);
    std.debug.print("Signature -> JSON: {s}\n", .{sig_json});

    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();

    const parsed_sig = try serde.json.fromSlice(Signature, arena2.allocator(), sig_json);
    std.debug.print("Signature <- JSON: payload=", .{});
    for (parsed_sig.payload.data) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print(", algorithm=\"{s}\"\n", .{parsed_sig.algorithm});
}
