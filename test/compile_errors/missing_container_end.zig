const serde = @import("serde");
const S = struct {
    pub const Error = error{Failure};
    pub fn serializeBool(_: *S, _: bool) Error!void {}
    pub const serializeInt = serializeBool;
    pub const serializeFloat = serializeBool;
    pub const serializeString = serializeBool;
    pub fn serializeNull(_: *S) Error!void {}
    pub const serializeVoid = serializeNull;
    pub fn beginArray(_: *S) Error!S {
        return .{};
    }
    pub const beginStruct = beginArray;
};
pub fn main() void {
    comptime serde.core.assertSerializer(S);
}
