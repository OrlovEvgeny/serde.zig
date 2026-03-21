const std = @import("std");
const scanner_mod = @import("scanner.zig");
const core_deserialize = @import("../../core/deserialize.zig");

const Scanner = scanner_mod.Scanner;
const Token = scanner_mod.Token;
const Allocator = std.mem.Allocator;

pub const DeserializeError = error{
    OutOfMemory,
    UnexpectedToken,
    UnexpectedEof,
    UnknownField,
    MissingField,
    InvalidNumber,
    WrongType,
    Overflow,
    MalformedXml,
};

pub const Deserializer = struct {
    scanner: Scanner,
    borrow_strings: bool = false,

    pub const Error = DeserializeError;

    pub fn init(input: []const u8) Deserializer {
        return .{ .scanner = .{ .input = input } };
    }

    pub fn initBorrowed(input: []const u8) Deserializer {
        return .{ .scanner = .{ .input = input }, .borrow_strings = true };
    }

    pub fn deserializeBool(self: *Deserializer) Error!bool {
        const text = try self.readTextContent();
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) return true;
        if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) return false;
        return error.WrongType;
    }

    pub fn deserializeInt(self: *Deserializer, comptime T: type) Error!T {
        const text = try self.readTextContent();
        return std.fmt.parseInt(T, text, 10) catch error.InvalidNumber;
    }

    pub fn deserializeFloat(self: *Deserializer, comptime T: type) Error!T {
        const text = try self.readTextContent();
        if (text.len == 0) return 0;
        return std.fmt.parseFloat(T, text) catch error.InvalidNumber;
    }

    pub fn deserializeString(self: *Deserializer, allocator: Allocator) Error![]const u8 {
        const text = try self.readTextContent();
        if (!Scanner.textHasEntities(text)) {
            if (self.borrow_strings) return text;
            const copy = allocator.alloc(u8, text.len) catch return error.OutOfMemory;
            @memcpy(copy, text);
            return copy;
        }
        if (self.borrow_strings) return error.MalformedXml;
        return Scanner.unescapeEntities(allocator, text) catch error.MalformedXml;
    }

    pub fn deserializeVoid(self: *Deserializer) Error!void {
        // Accept self-closing or empty element.
        const tok = try self.scanner.peek();
        switch (tok) {
            .self_closing => {
                _ = try self.scanner.next();
                return;
            },
            .text => {
                _ = try self.scanner.next();
                return;
            },
            .element_close => {
                _ = try self.scanner.next();
                return;
            },
            else => return,
        }
    }

    pub fn deserializeOptional(self: *Deserializer, comptime T: type, allocator: Allocator) Error!?T {
        const tok = try self.scanner.peek();
        // Self-closing element means null.
        if (tok == .self_closing) {
            _ = try self.scanner.next();
            return null;
        }
        return try core_deserialize.deserialize(T, allocator, self, .{});
    }

    pub fn deserializeEnum(self: *Deserializer, comptime T: type) Error!T {
        const text = try self.readTextContent();
        inline for (@typeInfo(T).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name))
                return @enumFromInt(field.value);
        }
        return error.UnexpectedToken;
    }

    pub fn deserializeUnion(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        const info = @typeInfo(T).@"union";
        // External tagging: element name is the variant discriminator.
        const tok = try self.scanner.next();
        switch (tok) {
            .element_open => |name| {
                inline for (info.fields) |field| {
                    if (std.mem.eql(u8, name, field.name)) {
                        if (field.type == void) {
                            // Consume until closing tag.
                            try self.skipToClose(name);
                            return @unionInit(T, field.name, {});
                        } else {
                            const payload = try core_deserialize.deserialize(field.type, allocator, self, .{});
                            try self.skipToClose(name);
                            return @unionInit(T, field.name, payload);
                        }
                    }
                }
                return error.UnexpectedToken;
            },
            .self_closing => |name| {
                inline for (info.fields) |field| {
                    if (field.type == void and std.mem.eql(u8, name, field.name)) {
                        return @unionInit(T, field.name, {});
                    }
                }
                return error.UnexpectedToken;
            },
            .text => |text| {
                // Try to match as a void variant by name.
                inline for (info.fields) |field| {
                    if (field.type == void and std.mem.eql(u8, text, field.name)) {
                        return @unionInit(T, field.name, {});
                    }
                }
                return error.UnexpectedToken;
            },
            else => return error.WrongType,
        }
    }

    pub fn deserializeStruct(self: *Deserializer, comptime _: type) Error!MapAccess {
        return .{ .scanner = &self.scanner, .borrow_strings = self.borrow_strings, .phase = .attributes };
    }

    pub fn deserializeSeq(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .slice)
            @compileError("deserializeSeq expects a slice type");
        const Child = info.pointer.child;

        var items: std.ArrayList(Child) = .empty;
        errdefer items.deinit(allocator);

        while (true) {
            const tok = try self.scanner.peek();
            switch (tok) {
                .element_open => {
                    _ = try self.scanner.next(); // consume <item>
                    const elem = try core_deserialize.deserialize(Child, allocator, self, .{});
                    items.append(allocator, elem) catch return error.OutOfMemory;
                    // Consume closing </item>.
                    const close = try self.scanner.next();
                    if (close != .element_close) return error.MalformedXml;
                },
                .self_closing => {
                    _ = try self.scanner.next();
                    // Self-closing <item/> — for optional/void children.
                    if (@typeInfo(Child) == .optional) {
                        items.append(allocator, null) catch return error.OutOfMemory;
                    }
                },
                .element_close, .eof => break,
                .text => {
                    // Text between elements — could be whitespace, skip.
                    _ = try self.scanner.next();
                    continue;
                },
                else => break,
            }
        }

        return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    pub fn deserializeSeqAccess(self: *Deserializer) Error!SeqAccess {
        return .{ .scanner = &self.scanner, .borrow_strings = self.borrow_strings };
    }

    pub fn raiseError(_: *Deserializer, err: anyerror) Error {
        return errorFromAny(err);
    }

    fn readTextContent(self: *Deserializer) Error![]const u8 {
        const tok = try self.scanner.next();
        switch (tok) {
            .text => |text| return text,
            .cdata => |data| return data,
            .self_closing => return "",
            .element_close => return "",
            .eof => return "",
            else => return error.WrongType,
        }
    }

    fn skipToClose(self: *Deserializer, name: []const u8) Error!void {
        // Consume tokens until we find the matching closing tag.
        while (true) {
            const tok = try self.scanner.next();
            switch (tok) {
                .element_close => |close_name| {
                    if (std.mem.eql(u8, close_name, name)) return;
                },
                .eof => return error.UnexpectedEof,
                else => continue,
            }
        }
    }
};

pub const MapAccess = struct {
    scanner: *Scanner,
    borrow_strings: bool = false,
    phase: Phase = .attributes,
    pending_attr_value: ?[]const u8 = null,

    const Phase = enum { attributes, children };

    pub const Error = DeserializeError;

    pub fn nextKey(self: *MapAccess, _: Allocator) Error!?[]const u8 {
        // If we have a pending attribute value that wasn't consumed, skip it.
        if (self.pending_attr_value != null) {
            self.pending_attr_value = null;
        }

        if (self.phase == .attributes) {
            const tok = try self.scanner.peek();
            switch (tok) {
                .attribute => {
                    const attr = (try self.scanner.next()).attribute;
                    self.pending_attr_value = attr.value;
                    return attr.name;
                },
                .tag_end => {
                    _ = try self.scanner.next();
                    self.phase = .children;
                },
                .self_closing => {
                    _ = try self.scanner.next();
                    return null;
                },
                else => {
                    self.phase = .children;
                },
            }
        }

        // Children phase.
        while (true) {
            const tok = try self.scanner.peek();
            switch (tok) {
                .element_open => |name| {
                    _ = try self.scanner.next();
                    return name;
                },
                .self_closing => |name| {
                    _ = try self.scanner.next();
                    return name;
                },
                .element_close => {
                    _ = try self.scanner.next();
                    return null;
                },
                .text => {
                    // Skip whitespace-only text between elements.
                    _ = try self.scanner.next();
                    continue;
                },
                .eof => return null,
                else => return null,
            }
        }
    }

    pub fn nextValue(self: *MapAccess, comptime T: type, allocator: Allocator) Error!T {
        // Attribute value from pending.
        if (self.pending_attr_value) |val| {
            self.pending_attr_value = null;
            return deserializeFromText(T, val, allocator, self.borrow_strings);
        }

        // Child element value.
        var deser = Deserializer{ .scanner = self.scanner.*, .borrow_strings = self.borrow_strings };
        const result = try core_deserialize.deserialize(T, allocator, &deser, .{});
        self.scanner.* = deser.scanner;

        // Consume the closing tag of this child element.
        const tok = try self.scanner.peek();
        if (tok == .element_close) {
            _ = try self.scanner.next();
        }

        return result;
    }

    pub fn skipValue(self: *MapAccess) Error!void {
        if (self.pending_attr_value != null) {
            self.pending_attr_value = null;
            return;
        }
        // Skip child element content until its closing tag.
        var depth: u32 = 1;
        while (depth > 0) {
            const tok = try self.scanner.next();
            switch (tok) {
                .element_open => {
                    // Need to handle the in_tag state.
                    while (true) {
                        const inner = try self.scanner.next();
                        switch (inner) {
                            .attribute => continue,
                            .tag_end => {
                                depth += 1;
                                break;
                            },
                            .self_closing => break,
                            else => {
                                depth += 1;
                                break;
                            },
                        }
                    }
                },
                .element_close => depth -= 1,
                .eof => return error.UnexpectedEof,
                else => continue,
            }
        }
    }

    pub fn raiseError(_: *MapAccess, err: anyerror) Error {
        return errorFromAny(err);
    }
};

pub const SeqAccess = struct {
    scanner: *Scanner,
    borrow_strings: bool = false,

    pub const Error = DeserializeError;

    pub fn nextElement(self: *SeqAccess, comptime T: type, allocator: Allocator) Error!?T {
        while (true) {
            const tok = try self.scanner.peek();
            switch (tok) {
                .element_open => {
                    _ = try self.scanner.next();
                    var deser = Deserializer{ .scanner = self.scanner.*, .borrow_strings = self.borrow_strings };
                    const result = try core_deserialize.deserialize(T, allocator, &deser, .{});
                    self.scanner.* = deser.scanner;
                    // Consume closing tag.
                    const close = try self.scanner.peek();
                    if (close == .element_close) {
                        _ = try self.scanner.next();
                    }
                    return result;
                },
                .self_closing => {
                    _ = try self.scanner.next();
                    if (@typeInfo(T) == .optional) return null;
                    return null;
                },
                .element_close, .eof => return null,
                .text => {
                    _ = try self.scanner.next();
                    continue;
                },
                else => return null,
            }
        }
    }
};

fn deserializeFromText(comptime T: type, text: []const u8, allocator: Allocator, borrow: bool) DeserializeError!T {
    const k = comptime @import("../../core/kind.zig").typeKind(T);
    if (k == .bool) {
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) return true;
        if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) return false;
        return error.WrongType;
    } else if (k == .int) {
        return std.fmt.parseInt(T, text, 10) catch error.InvalidNumber;
    } else if (k == .float) {
        return std.fmt.parseFloat(T, text) catch error.InvalidNumber;
    } else if (k == .string) {
        if (!Scanner.textHasEntities(text)) {
            if (borrow) return text;
            const copy = allocator.alloc(u8, text.len) catch return error.OutOfMemory;
            @memcpy(copy, text);
            return copy;
        }
        return Scanner.unescapeEntities(allocator, text) catch error.MalformedXml;
    } else if (k == .@"enum") {
        inline for (@typeInfo(T).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name))
                return @enumFromInt(field.value);
        }
        return error.UnexpectedToken;
    } else {
        return error.WrongType;
    }
}

fn errorFromAny(err: anyerror) DeserializeError {
    return switch (err) {
        error.UnknownField => error.UnknownField,
        error.MissingField => error.MissingField,
        error.UnexpectedEof => error.UnexpectedEof,
        error.OutOfMemory => error.OutOfMemory,
        error.MalformedXml => error.MalformedXml,
        else => error.WrongType,
    };
}

// Tests.

const testing = std.testing;

test "deserialize bool" {
    var d = Deserializer.init("true");
    try testing.expectEqual(true, try d.deserializeBool());
}

test "deserialize bool 1/0" {
    var d = Deserializer.init("1");
    try testing.expectEqual(true, try d.deserializeBool());
    var d2 = Deserializer.init("0");
    try testing.expectEqual(false, try d2.deserializeBool());
}

test "deserialize int" {
    var d = Deserializer.init("42");
    try testing.expectEqual(@as(i32, 42), try d.deserializeInt(i32));
}

test "deserialize negative int" {
    var d = Deserializer.init("-7");
    try testing.expectEqual(@as(i32, -7), try d.deserializeInt(i32));
}

test "deserialize float" {
    var d = Deserializer.init("3.14");
    const val = try d.deserializeFloat(f64);
    try testing.expect(@abs(val - 3.14) < 0.001);
}

test "deserialize string" {
    var d = Deserializer.init("hello");
    const s = try d.deserializeString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello", s);
}

test "deserialize string with entities" {
    var d = Deserializer.init("a&amp;b&lt;c");
    const s = try d.deserializeString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a&b<c", s);
}

test "deserialize enum" {
    const Color = enum { red, green, blue };
    var d = Deserializer.init("green");
    try testing.expectEqual(Color.green, try d.deserializeEnum(Color));
}

test "deserialize struct" {
    const Point = struct { x: i32, y: i32 };
    var d = Deserializer.init("<x>10</x><y>20</y>");
    const point = try core_deserialize.deserialize(Point, testing.allocator, &d, .{});
    try testing.expectEqual(@as(i32, 10), point.x);
    try testing.expectEqual(@as(i32, 20), point.y);
}

test "deserialize struct with optional missing" {
    const Opt = struct { a: i32, b: ?i32 };
    // Only 'a' present, 'b' should default to null.
    var d = Deserializer.init("<a>5</a>");
    const val = try core_deserialize.deserialize(Opt, testing.allocator, &d, .{});
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(?i32, null), val.b);
}

test "deserialize struct with attributes" {
    const Tag = struct { id: i32, name: []const u8 };
    // Attributes come from in-tag parsing.
    var d = Deserializer.init("<root id=\"42\" name=\"test\">");
    // Manually enter in_tag state by consuming element_open.
    _ = try d.scanner.next(); // element_open "root"
    var map = try d.deserializeStruct(Tag);
    const k1 = try map.nextKey(testing.allocator);
    try testing.expectEqualStrings("id", k1.?);
    const v1 = try map.nextValue(i32, testing.allocator);
    try testing.expectEqual(@as(i32, 42), v1);
    const k2 = try map.nextKey(testing.allocator);
    try testing.expectEqualStrings("name", k2.?);
    const v2 = try map.nextValue([]const u8, testing.allocator);
    defer testing.allocator.free(v2);
    try testing.expectEqualStrings("test", v2);
}

test "wrong type error" {
    var d = Deserializer.init("<elem>text</elem>");
    _ = try d.scanner.next(); // consume element_open
    try testing.expectError(error.WrongType, d.deserializeBool());
}
