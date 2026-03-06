/// Unix timestamp helper for `serde.with`. Identity transform: i64 <-> i64.
/// Use with fields that store Unix epoch seconds.
pub const UnixTimestamp = struct {
    pub const WireType = i64;

    pub fn serialize(value: i64) i64 {
        return value;
    }

    pub fn deserialize(raw: i64) i64 {
        return raw;
    }
};

/// Unix timestamp in milliseconds. Converts between ms (wire) and seconds (field).
pub const UnixTimestampMs = struct {
    pub const WireType = i64;

    pub fn serialize(value: i64) i64 {
        return value * 1000;
    }

    pub fn deserialize(raw: i64) i64 {
        return @divTrunc(raw, 1000);
    }
};

const testing = @import("std").testing;

test "UnixTimestamp identity" {
    const ts: i64 = 1700000000;
    try testing.expectEqual(ts, UnixTimestamp.serialize(ts));
    try testing.expectEqual(ts, UnixTimestamp.deserialize(ts));
}

test "UnixTimestampMs conversion" {
    const secs: i64 = 1700000000;
    const ms = UnixTimestampMs.serialize(secs);
    try testing.expectEqual(secs * 1000, ms);
    try testing.expectEqual(secs, UnixTimestampMs.deserialize(ms));
}
