const serde = @import("serde");
const S = struct {
    pub const Error = error{Failure};
    pub fn serializeBool(_: *S, _: bool) error{Undeclared}!void {}
    pub fn serializeInt(_: *S, _: anytype) Error!void {}
    pub const serializeFloat = serializeInt;
    pub fn serializeString(_: *S, _: []const u8) Error!void {}
    pub fn serializeNull(_: *S) Error!void {}
    pub const serializeVoid = serializeNull;
    pub fn beginArray(_: *S) Error!S {
        return .{};
    }
    pub const beginStruct = beginArray;
    pub fn serializeField(_: *S, comptime _: []const u8, _: anytype) Error!void {}
    pub fn serializeEntry(_: *S, _: anytype, _: anytype) Error!void {}
    pub fn end(_: *S) Error!void {}
};
pub fn main() void {
    comptime serde.core.assertSerializer(S);
}
