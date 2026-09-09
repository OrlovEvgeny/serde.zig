const std = @import("std");
const serde = @import("serde");
test "built-in full contracts" {
    comptime {
        for (.{ serde.json, serde.msgpack, serde.zon, serde.xml, serde.yaml, serde.etf }) |format| {
            serde.core.assertSerializer(if (@TypeOf(format.Serializer) == type) format.Serializer else format.Serializer(.{}));
            serde.core.assertDeserializer(format.Deserializer);
        }
    }
}
test "legacy predicates retain their permissive behavior" {
    const Legacy = struct {
        pub const serializeBool = void;
        pub const serializeInt = void;
        pub const serializeFloat = void;
        pub const serializeString = void;
        pub const serializeNull = void;
        pub const serializeVoid = void;
        pub const beginArray = void;
        pub const beginStruct = void;
    };
    try std.testing.expect(serde.core.isSerializer(Legacy));
}
test "releaseString respects explicit borrowing" {
    const D = struct {
        bytes: []const u8,
        pub const serde_protocol = struct {
            pub fn borrowedInput(d: *const Parent) ?[]const u8 {
                return d.bytes;
            }
        };
        const Parent = @This();
    };
    var d = D{ .bytes = "borrowed" };
    serde.core.releaseString(&d, std.testing.allocator, d.bytes);
    serde.core.releaseString(&d, std.testing.allocator, try std.testing.allocator.dupe(u8, "owned"));
}
