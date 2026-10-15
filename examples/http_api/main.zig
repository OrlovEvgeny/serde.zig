const std = @import("std");
const serde = @import("serde");
const options = serde;

const Event = union(enum) {
    created: struct { order_id: []const u8, total_cents: u64 },
    shipped: struct { order_id: []const u8, tracking_number: []const u8 },
    cancelled: struct { order_id: []const u8, reason: []const u8 },

    pub const serde = .{ .tag = options.UnionTag.internal, .tag_field = "event_type" };
};
const Metadata = struct {
    request_id: []const u8,
    received_at: i64,

    pub const serde = .{ .rename_all = options.NamingConvention.camel_case };
};
const Acknowledgement = struct {
    order_id: []const u8,
    status: enum { queued, tracking_updated, cancelled },
    tracking_number: ?[]const u8 = null,
    internal_token: []const u8 = "",
    metadata: Metadata,

    pub const serde = .{
        .rename_all = options.NamingConvention.camel_case,
        .skip = .{
            .internal_token = options.SkipMode.always,
            .tracking_number = options.SkipMode.null,
        },
        .flatten = &[_][]const u8{"metadata"},
    };
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const body = try serde.compat.readFileAlloc(allocator, "examples/http_api/webhook.json", 64 * 1024);
    defer allocator.free(body);
    var event = try serde.json.fromSliceManaged(Event, allocator, body);
    defer event.deinit();

    // This is the serialization layer of a handler. A server would supply the
    // authenticated request body, request ID and clock value.
    var ack = Acknowledgement{
        .order_id = "",
        .status = .queued,
        .internal_token = "example-internal-token",
        .metadata = .{ .request_id = "req-7f32", .received_at = 1700000000 },
    };
    switch (event.value) {
        .created => |order| {
            if (order.total_cents == 0) return error.EmptyOrder;
            ack.order_id = order.order_id;
        },
        .shipped => |shipment| {
            if (shipment.tracking_number.len == 0) return error.MissingTrackingNumber;
            ack.order_id = shipment.order_id;
            ack.status = .tracking_updated;
            ack.tracking_number = shipment.tracking_number;
        },
        .cancelled => |cancellation| {
            if (cancellation.reason.len == 0) return error.MissingCancellationReason;
            ack.order_id = cancellation.order_id;
            ack.status = .cancelled;
        },
    }
    if (ack.order_id.len == 0) return error.MissingOrderId;

    const response = try serde.json.toSliceWith(allocator, ack, .{ .pretty = true });
    defer allocator.free(response);
    std.debug.print("HTTP 202 application/json (simulated handler)\n", .{});
    try serde.compat.writeStdout(response);
    try serde.compat.writeStdout("\n");
}
