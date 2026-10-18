const std = @import("std");
const serde = @import("serde");
const D = struct {
    pub const Error = error{OutOfMemory};
    pub fn deserializeBool(_: *D) Error!bool {
        return false;
    }
    pub fn deserializeInt(_: *D, comptime T: type) Error!T {
        return 0;
    }
    pub const deserializeFloat = deserializeInt;
    pub fn deserializeString(_: *D, _: std.mem.Allocator) Error![]const u8 {
        return "";
    }
    pub fn deserializeStringOwned(_: *D, _: std.mem.Allocator) error{Undeclared}![]u8 {
        return error.Undeclared;
    }
    pub fn deserializeVoid(_: *D) Error!void {}
    pub fn deserializeOptional(_: *D, comptime T: type, _: std.mem.Allocator) Error!?T {
        return null;
    }
    pub fn deserializeStruct(_: *D, comptime _: type) Error!D {
        return .{};
    }
    pub fn deserializeSeqAccess(_: *D) Error!D {
        return .{};
    }
    pub fn deserializeEnum(_: *D, comptime T: type) Error!T {
        return undefined;
    }
    pub fn deserializeUnion(_: *D, comptime T: type, _: std.mem.Allocator) Error!T {
        return undefined;
    }
    pub fn raiseError(_: *D, _: anyerror) Error {
        return error.OutOfMemory;
    }
    pub fn nextKey(_: *D, _: std.mem.Allocator) Error!?[]const u8 {
        return null;
    }
    pub fn nextValue(_: *D, comptime T: type, _: std.mem.Allocator) Error!T {
        return undefined;
    }
    pub fn skipValue(_: *D) Error!void {}
    pub fn nextElement(_: *D, comptime T: type, _: std.mem.Allocator) Error!?T {
        return null;
    }
};
pub fn main() void {
    comptime serde.core.assertDeserializer(D);
}
