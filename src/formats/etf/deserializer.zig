const std = @import("std");
const compat = @import("compat");
const core_deserialize = @import("../../core/deserialize.zig");
const reflect = @import("../../reflect.zig");
const codec = @import("codec.zig");

const Allocator = std.mem.Allocator;

/// Worst-case decoded atom size: 255 Latin-1 code points, two UTF-8 bytes
/// each. UTF-8 atoms are borrowed from the input and never hit this buffer.
const atom_buffer_len = 510;

pub const DeserializeError = codec.DecodeError || error{
    UnknownField,
    MissingField,
    DuplicateField,
    WrongType,
    WithFailed,
    InvalidNumber,
};

/// Direct typed ETF decoder. It consumes the shared wire representation
/// without first allocating a dynamic `Term` tree.
pub const Deserializer = struct {
    input: []const u8,
    pos: usize = 0,
    depth: usize = 0,
    options: codec.DecodeOptions,

    pub const Error = DeserializeError;

    pub fn init(input: []const u8, options: codec.DecodeOptions) Deserializer {
        return .{ .input = input, .options = options };
    }

    pub fn deserializeBool(self: *Deserializer) Error!bool {
        var buffer: [atom_buffer_len]u8 = undefined;
        const atom = try self.readAtomView(&buffer);
        if (std.mem.eql(u8, atom, "true")) return true;
        if (std.mem.eql(u8, atom, "false")) return false;
        return error.WrongType;
    }

    pub fn deserializeInt(self: *Deserializer, comptime T: type) Error!T {
        const tag = try self.readByte();
        return switch (tag) {
            @intFromEnum(codec.Tag.small_integer_ext) => castMagnitude(T, false, try self.readByte()),
            @intFromEnum(codec.Tag.integer_ext) => blk: {
                const signed: i32 = @bitCast(try self.readU32());
                if (signed < 0) break :blk castMagnitude(T, true, @as(u64, @intCast(-@as(i64, signed))));
                break :blk castMagnitude(T, false, @as(u32, @intCast(signed)));
            },
            @intFromEnum(codec.Tag.small_big_ext) => self.readMagnitude(T, try self.readByte()),
            @intFromEnum(codec.Tag.large_big_ext) => self.readMagnitude(T, try self.readU32()),
            else => return error.WrongType,
        };
    }

    pub fn deserializeFloat(self: *Deserializer, comptime T: type) Error!T {
        const saved = self.*;
        const tag = try self.readByte();
        switch (tag) {
            @intFromEnum(codec.Tag.new_float_ext) => {
                const value: f64 = @bitCast(try self.readU64());
                if (!std.math.isFinite(value)) return error.InvalidFloat;
                return @floatCast(value);
            },
            @intFromEnum(codec.Tag.float_ext) => {
                const bytes = try self.readSlice(31);
                const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
                const value = std.fmt.parseFloat(f64, bytes[0..end]) catch return error.InvalidFloat;
                if (!std.math.isFinite(value)) return error.InvalidFloat;
                return @floatCast(value);
            },
            else => {
                if (self.options.strict) return error.WrongType;
                self.* = saved;
                const value = try self.deserializeInt(i128);
                return @floatFromInt(value);
            },
        }
    }

    pub fn deserializeString(self: *Deserializer, allocator: Allocator) Error![]const u8 {
        return self.readString(allocator);
    }

    pub fn deserializeBytes(self: *Deserializer, allocator: Allocator) Error![]u8 {
        return @constCast(try self.readString(allocator));
    }

    pub fn deserializeVoid(self: *Deserializer) Error!void {
        if (!try self.consumeNull()) return error.WrongType;
    }

    pub fn deserializeOptional(self: *Deserializer, comptime T: type, allocator: Allocator) Error!?T {
        const saved = self.*;
        if (try self.consumeNull()) return null;
        self.* = saved;
        return try core_deserialize.deserialize(T, allocator, self, .{});
    }

    pub fn deserializeEnum(self: *Deserializer, comptime T: type) Error!T {
        var buffer: [atom_buffer_len]u8 = undefined;
        const name = try self.readNameView(&buffer);
        inline for (reflect.enumFields(T)) |field| {
            if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
        }
        return error.WrongType;
    }

    pub fn deserializeUnion(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        var buffer: [atom_buffer_len]u8 = undefined;
        {
            const saved = self.*;
            if (self.readNameView(&buffer)) |name| {
                inline for (reflect.unionFields(T)) |field| {
                    if (field.type == void and std.mem.eql(u8, name, field.name))
                        return @unionInit(T, field.name, {});
                }
                self.* = saved;
            } else |_| self.* = saved;
        }

        const tag = try self.readByte();
        if (tag != @intFromEnum(codec.Tag.map_ext)) return error.WrongType;
        if (try self.readU32() != 1) return error.WrongType;
        try self.enterContainer();
        defer self.depth -= 1;
        const name = try self.readNameView(&buffer);
        inline for (reflect.unionFields(T)) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                if (field.type == void) {
                    try self.skipValue();
                    return @unionInit(T, field.name, {});
                }
                return @unionInit(T, field.name, try core_deserialize.deserialize(field.type, allocator, self, .{}));
            }
        }
        return error.WrongType;
    }

    pub fn deserializeStruct(self: *Deserializer, comptime _: type) Error!MapAccess {
        const tag = try self.readByte();
        if (tag != @intFromEnum(codec.Tag.map_ext)) return error.WrongType;
        const count: usize = try self.readU32();
        try self.checkCollection(count);
        try self.enterContainer();
        return .{ .parent = self, .remaining = count, .depth_entered = true };
    }

    pub fn deserializeSeq(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .slice)
            @compileError("deserializeSeq expects a slice type");
        const Child = info.pointer.child;
        var access = try self.deserializeSeqAccess();
        const count = access.remaining;
        const items = allocator.alloc(Child, count) catch return error.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| core_deserialize.freeAllocated(Child, item, allocator);
            allocator.free(items);
        }
        for (items) |*item| {
            item.* = (try access.nextElement(Child, allocator)) orelse return error.UnexpectedEof;
            initialized += 1;
        }
        if (try access.nextElement(Child, allocator) != null) return error.WrongType;
        return items;
    }

    pub fn deserializeSeqAccess(self: *Deserializer) Error!SeqAccess {
        const tag = try self.readByte();
        try self.enterContainer();
        errdefer self.depth -= 1;
        const count: usize = switch (tag) {
            @intFromEnum(codec.Tag.list_ext) => try self.readU32(),
            @intFromEnum(codec.Tag.nil_ext) => return .{ .parent = self, .remaining = 0, .tail_consumed = true, .depth_entered = true },
            @intFromEnum(codec.Tag.small_tuple_ext) => if (!self.options.strict) try self.readByte() else return error.WrongType,
            @intFromEnum(codec.Tag.large_tuple_ext) => if (!self.options.strict) try self.readU32() else return error.WrongType,
            else => return error.WrongType,
        };
        try self.checkCollection(count);
        const tuple = tag == @intFromEnum(codec.Tag.small_tuple_ext) or tag == @intFromEnum(codec.Tag.large_tuple_ext);
        return .{ .parent = self, .remaining = count, .tail_consumed = tuple, .depth_entered = true };
    }

    pub fn raiseError(_: *Deserializer, err: anyerror) Error {
        return errorFromAny(err);
    }

    fn readString(self: *Deserializer, allocator: Allocator) Error![]u8 {
        const tag = try self.readByte();
        if (tag == @intFromEnum(codec.Tag.binary_ext)) {
            return self.copyBytes(allocator, try self.readU32());
        }
        if (self.options.strict) return error.WrongType;
        if (tag == @intFromEnum(codec.Tag.string_ext)) return self.copyBytes(allocator, try self.readU16());
        if (tag == @intFromEnum(codec.Tag.nil_ext)) return allocator.alloc(u8, 0) catch error.OutOfMemory;
        if (tag != @intFromEnum(codec.Tag.list_ext)) return error.WrongType;
        const count: usize = try self.readU32();
        try self.checkCollection(count);
        try self.enterContainer();
        defer self.depth -= 1;
        const out = allocator.alloc(u8, count) catch return error.OutOfMemory;
        errdefer allocator.free(out);
        for (out) |*byte| byte.* = try self.deserializeInt(u8);
        if (try self.readByte() != @intFromEnum(codec.Tag.nil_ext)) return error.WrongType;
        return out;
    }

    fn consumeNull(self: *Deserializer) Error!bool {
        const saved = self.*;
        const tag = try self.readByte();
        if (!self.options.strict and tag == @intFromEnum(codec.Tag.nil_ext)) return true;
        self.* = saved;
        var buffer: [atom_buffer_len]u8 = undefined;
        const atom = self.readAtomView(&buffer) catch {
            self.* = saved;
            return false;
        };
        if (std.mem.eql(u8, atom, "null")) return true;
        if (!self.options.strict and (std.mem.eql(u8, atom, "nil") or std.mem.eql(u8, atom, "undefined"))) return true;
        self.* = saved;
        return false;
    }

    fn readNameView(self: *Deserializer, buffer: *[atom_buffer_len]u8) Error![]const u8 {
        const saved = self.*;
        const tag = try self.readByte();
        if (tag == @intFromEnum(codec.Tag.binary_ext)) return self.readSlice(try self.readU32());
        self.* = saved;
        if (self.options.strict) return error.WrongType;
        return self.readAtomView(buffer);
    }

    /// Decodes an atom without allocating: UTF-8 atoms and cache hits are
    /// borrowed from the input or cache, Latin-1 atoms are transcoded into
    /// `buffer`.
    fn readAtomView(self: *Deserializer, buffer: *[atom_buffer_len]u8) Error![]const u8 {
        const tag = try self.readByte();
        return switch (tag) {
            @intFromEnum(codec.Tag.small_atom_utf8_ext) => self.readUtf8AtomView(try self.readByte()),
            @intFromEnum(codec.Tag.atom_utf8_ext) => self.readUtf8AtomView(try self.readU16()),
            @intFromEnum(codec.Tag.small_atom_ext) => self.readLatin1AtomView(buffer, try self.readByte()),
            @intFromEnum(codec.Tag.atom_ext) => self.readLatin1AtomView(buffer, try self.readU16()),
            @intFromEnum(codec.Tag.atom_cache_ref) => blk: {
                const index = try self.readByte();
                const cache = self.options.atom_cache orelse return error.MissingAtomCache;
                if (index >= cache.len) return error.InvalidAtomCacheRef;
                const atom = cache[index];
                if (!std.unicode.utf8ValidateSlice(atom)) return error.InvalidAtom;
                if ((std.unicode.utf8CountCodepoints(atom) catch return error.InvalidAtom) > 255) return error.AtomTooLong;
                break :blk atom;
            },
            else => error.WrongType,
        };
    }

    fn readUtf8AtomView(self: *Deserializer, count: usize) Error![]const u8 {
        const raw = try self.readSlice(count);
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidAtom;
        if ((std.unicode.utf8CountCodepoints(raw) catch return error.InvalidAtom) > 255) return error.AtomTooLong;
        return raw;
    }

    fn readLatin1AtomView(self: *Deserializer, buffer: *[atom_buffer_len]u8, count: usize) Error![]const u8 {
        if (count > 255) return error.AtomTooLong;
        const raw = try self.readSlice(count);
        var at: usize = 0;
        for (raw) |byte| {
            if (byte < 0x80) {
                buffer[at] = byte;
                at += 1;
            } else {
                buffer[at] = 0xc0 | (byte >> 6);
                buffer[at + 1] = 0x80 | (byte & 0x3f);
                at += 2;
            }
        }
        return buffer[0..at];
    }

    fn readMagnitude(self: *Deserializer, comptime T: type, count: usize) Error!T {
        if (count > self.options.max_bignum_bytes) return error.BignumLimit;
        const sign = try self.readByte();
        if (sign > 1) return error.InvalidIdentifier;
        const bytes = try self.readSlice(count);
        const bits = @typeInfo(T).int.bits;
        const Work = compat.intType(.unsigned, @max(bits, 8));
        var magnitude: Work = 0;
        for (bytes, 0..) |byte, i| {
            const shift = std.math.mul(usize, i, 8) catch return error.Overflow;
            if (shift >= @bitSizeOf(Work)) {
                if (byte != 0) return error.Overflow;
                continue;
            }
            const available = @bitSizeOf(Work) - shift;
            if (available < 8 and byte >= (@as(u8, 1) << @intCast(available))) return error.Overflow;
            magnitude |= @as(Work, byte) << @intCast(shift);
        }
        return castMagnitude(T, sign == 1 and magnitude != 0, magnitude);
    }

    fn skipValue(self: *Deserializer) Error!void {
        try self.skipTerm(self.depth);
    }

    /// Streaming skip of one wire term without materializing it. Structural
    /// limits (depth, collection and bignum sizes) match the decoder, but
    /// content validation of skipped scalars is not repeated.
    fn skipTerm(self: *Deserializer, depth: usize) Error!void {
        if (depth >= self.options.max_depth) return error.DepthLimit;
        const tag_byte = try self.readByte();
        const tag = compat.intToEnum(codec.Tag, tag_byte) orelse return error.UnexpectedTag;
        switch (tag) {
            .small_integer_ext, .atom_cache_ref => _ = try self.readByte(),
            .integer_ext => _ = try self.readSlice(4),
            .new_float_ext => _ = try self.readSlice(8),
            .float_ext => _ = try self.readSlice(31),
            .small_big_ext => try self.skipBig(try self.readByte()),
            .large_big_ext => try self.skipBig(try self.readU32()),
            .atom_utf8_ext, .atom_ext => _ = try self.readSlice(try self.readU16()),
            .small_atom_utf8_ext, .small_atom_ext => _ = try self.readSlice(try self.readByte()),
            .new_pid_ext, .v4_port_ext => {
                try self.skipTerm(depth + 1);
                _ = try self.readSlice(12);
            },
            .pid_ext => {
                try self.skipTerm(depth + 1);
                _ = try self.readSlice(9);
            },
            .new_port_ext => {
                try self.skipTerm(depth + 1);
                _ = try self.readSlice(8);
            },
            .port_ext, .reference_ext => {
                try self.skipTerm(depth + 1);
                _ = try self.readSlice(5);
            },
            .new_reference_ext, .newer_reference_ext => {
                const count: usize = try self.readU16();
                if (count == 0 or count > 5) return error.InvalidIdentifier;
                try self.skipTerm(depth + 1);
                const creation_len: usize = if (tag == .newer_reference_ext) 4 else 1;
                _ = try self.readSlice(creation_len + 4 * count);
            },
            .small_tuple_ext => try self.skipTerms(try self.readByte(), depth),
            .large_tuple_ext => {
                const count: usize = try self.readU32();
                try self.checkCollection(count);
                try self.skipTerms(count, depth);
            },
            .map_ext => {
                const count: usize = try self.readU32();
                try self.checkCollection(count);
                for (0..count) |_| {
                    try self.skipTerm(depth + 1);
                    try self.skipTerm(depth + 1);
                }
            },
            .nil_ext => {},
            .string_ext => _ = try self.readSlice(try self.readU16()),
            .list_ext => {
                const count: usize = try self.readU32();
                try self.checkCollection(count);
                try self.skipTerms(count, depth);
                try self.skipTerm(depth + 1);
            },
            .binary_ext => _ = try self.readSlice(try self.readU32()),
            .bit_binary_ext => {
                const count: usize = try self.readU32();
                _ = try self.readByte();
                _ = try self.readSlice(count);
            },
            .new_fun_ext => {
                const start = self.pos;
                const size: usize = try self.readU32();
                if (size < 4) return error.InvalidFun;
                const end = std.math.add(usize, start, size) catch return error.InvalidFun;
                if (end > self.input.len) return error.UnexpectedEof;
                self.pos = end;
            },
            .fun_ext => {
                const num_free: usize = try self.readU32();
                try self.checkCollection(num_free);
                try self.skipTerms(4, depth); // pid, module, index, uniq
                try self.skipTerms(num_free, depth);
            },
            .export_ext => try self.skipTerms(3, depth),
            .record_ext => {
                const count: usize = try self.readU32();
                try self.checkCollection(count);
                _ = try self.readByte(); // flags
                try self.skipTerms(2, depth); // module, name
                try self.skipTerms(count, depth); // field names
                try self.skipTerms(count, depth); // values
            },
            .local_ext => return error.InvalidLocalTerm,
            .compressed_ext => return error.UnexpectedTag,
        }
    }

    fn skipTerms(self: *Deserializer, count: usize, depth: usize) Error!void {
        for (0..count) |_| try self.skipTerm(depth + 1);
    }

    fn skipBig(self: *Deserializer, count: usize) Error!void {
        if (count > self.options.max_bignum_bytes) return error.BignumLimit;
        _ = try self.readByte();
        _ = try self.readSlice(count);
    }

    fn checkCollection(self: *Deserializer, count: usize) Error!void {
        if (count > self.options.max_collection_elements) return error.CollectionLimit;
    }

    fn enterContainer(self: *Deserializer) Error!void {
        if (self.depth >= self.options.max_depth) return error.DepthLimit;
        self.depth += 1;
    }

    fn copyBytes(self: *Deserializer, allocator: Allocator, count: usize) Error![]u8 {
        if (count > self.options.max_uncompressed_size) return error.SizeLimit;
        const raw = try self.readSlice(count);
        return allocator.dupe(u8, raw) catch error.OutOfMemory;
    }

    fn readByte(self: *Deserializer) Error!u8 {
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        const byte = self.input[self.pos];
        self.pos += 1;
        return byte;
    }

    fn readSlice(self: *Deserializer, count: usize) Error![]const u8 {
        const end = std.math.add(usize, self.pos, count) catch return error.Overflow;
        if (end > self.input.len) return error.UnexpectedEof;
        const out = self.input[self.pos..end];
        self.pos = end;
        return out;
    }

    fn readU16(self: *Deserializer) Error!u16 {
        const bytes = try self.readSlice(2);
        return std.mem.readInt(u16, bytes[0..2], .big);
    }

    fn readU32(self: *Deserializer) Error!u32 {
        const bytes = try self.readSlice(4);
        return std.mem.readInt(u32, bytes[0..4], .big);
    }

    fn readU64(self: *Deserializer) Error!u64 {
        const bytes = try self.readSlice(8);
        return std.mem.readInt(u64, bytes[0..8], .big);
    }
};

pub const MapAccess = struct {
    parent: *Deserializer,
    remaining: usize,
    key_buffer: [atom_buffer_len]u8 = undefined,
    depth_entered: bool = false,

    pub const Error = DeserializeError;

    pub fn nextKey(self: *MapAccess, _: Allocator) Error!?[]const u8 {
        if (self.remaining == 0) {
            if (self.depth_entered) {
                self.parent.depth -= 1;
                self.depth_entered = false;
            }
            return null;
        }
        const saved = self.parent.*;
        const tag = try self.parent.readByte();
        if (tag == @intFromEnum(codec.Tag.binary_ext)) {
            const count: usize = try self.parent.readU32();
            return try self.parent.readSlice(count);
        }
        self.parent.* = saved;
        if (tag == @intFromEnum(codec.Tag.small_integer_ext) or
            tag == @intFromEnum(codec.Tag.integer_ext) or
            tag == @intFromEnum(codec.Tag.small_big_ext) or
            tag == @intFromEnum(codec.Tag.large_big_ext))
        {
            const number = try self.parent.deserializeInt(i128);
            return std.fmt.bufPrint(&self.key_buffer, "{d}", .{number}) catch return error.Overflow;
        }
        if (self.parent.options.strict) return error.WrongType;
        return try self.parent.readAtomView(&self.key_buffer);
    }

    pub fn nextValue(self: *MapAccess, comptime T: type, allocator: Allocator) Error!T {
        self.remaining -= 1;
        return core_deserialize.deserialize(T, allocator, self.parent, .{});
    }

    pub fn skipValue(self: *MapAccess) Error!void {
        self.remaining -= 1;
        try self.parent.skipValue();
    }

    pub fn raiseError(_: *MapAccess, err: anyerror) Error {
        return errorFromAny(err);
    }
};

pub const SeqAccess = struct {
    parent: *Deserializer,
    remaining: usize,
    tail_consumed: bool = false,
    depth_entered: bool = false,

    pub const Error = DeserializeError;

    pub fn nextElement(self: *SeqAccess, comptime T: type, allocator: Allocator) Error!?T {
        if (self.remaining == 0) {
            if (!self.tail_consumed) {
                self.tail_consumed = true;
                if (try self.parent.readByte() != @intFromEnum(codec.Tag.nil_ext)) return error.WrongType;
            }
            if (self.depth_entered) {
                self.parent.depth -= 1;
                self.depth_entered = false;
            }
            return null;
        }
        self.remaining -= 1;
        return try core_deserialize.deserialize(T, allocator, self.parent, .{});
    }
};

fn castMagnitude(comptime T: type, negative: bool, magnitude: anytype) DeserializeError!T {
    const info = @typeInfo(T).int;
    const Work = compat.intType(.unsigned, @max(info.bits, @bitSizeOf(@TypeOf(magnitude)), 8));
    const wide: Work = @intCast(magnitude);
    if (info.signedness == .unsigned) {
        if (negative) return error.Overflow;
        return std.math.cast(T, wide) orelse error.Overflow;
    }
    if (!negative) return std.math.cast(T, wide) orelse error.Overflow;
    const limit: Work = @as(Work, 1) << @intCast(info.bits - 1);
    if (wide > limit) return error.Overflow;
    if (wide == limit) return std.math.minInt(T);
    const SignedWork = compat.intType(.signed, @bitSizeOf(Work) + 1);
    return @intCast(-@as(SignedWork, @intCast(wide)));
}

fn errorFromAny(err: anyerror) DeserializeError {
    return switch (err) {
        error.UnknownField => error.UnknownField,
        error.MissingField => error.MissingField,
        error.DuplicateField => error.DuplicateField,
        error.UnexpectedEof => error.UnexpectedEof,
        error.OutOfMemory => error.OutOfMemory,
        error.WithFailed => error.WithFailed,
        error.InvalidNumber => error.InvalidNumber,
        else => error.WrongType,
    };
}
