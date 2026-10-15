const std = @import("std");
const serde = @import("serde");

const LineItem = struct {
    sku: []const u8,
    quantity: u16,
    unit_price_cents: u32,
};
const Order = struct {
    order_id: []const u8,
    currency: []const u8,
    items: []const LineItem,
    note: ?[]const u8 = null,
};
const Receipt = struct {
    order_id: []const u8,
    currency: []const u8,
    item_count: u64,
    total_cents: u64,
    note: ?[]const u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = try serde.compat.readFileAlloc(allocator, "examples/basic_json/order.json", 64 * 1024);
    defer allocator.free(input);
    var order = try serde.json.fromSliceManaged(Order, allocator, input);
    defer order.deinit();

    if (order.value.order_id.len == 0 or order.value.items.len == 0) return error.EmptyOrder;
    if (!std.mem.eql(u8, order.value.currency, "EUR")) return error.UnsupportedCurrency;
    var total: u64 = 0;
    var count: u64 = 0;
    for (order.value.items) |item| {
        if (item.sku.len == 0 or item.quantity == 0) return error.InvalidLineItem;
        const line_total = @as(u64, item.quantity) * item.unit_price_cents;
        total = try std.math.add(u64, total, line_total);
        count = try std.math.add(u64, count, item.quantity);
    }

    // Integer minor units keep the calculation exact. The receipt borrows strings
    // from order, so serialize it before order.deinit().
    const receipt = Receipt{
        .order_id = order.value.order_id,
        .currency = order.value.currency,
        .item_count = count,
        .total_cents = total,
        .note = order.value.note,
    };
    const output = try serde.json.toSliceWith(allocator, receipt, .{ .pretty = true });
    defer allocator.free(output);
    try serde.compat.writeStdout(output);
    try serde.compat.writeStdout("\n");
}
