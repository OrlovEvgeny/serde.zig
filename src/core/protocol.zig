//! Optional backend capabilities. Declaring serde_protocol opts out of field inference.

pub fn Backend(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

fn Checkpoint(comptime D: type) type {
    if (@hasDecl(D, "serde_protocol")) {
        const P = D.serde_protocol;
        if (!@hasDecl(P, "checkpoint") or !@hasDecl(P, "restore"))
            @compileError(@typeName(D) ++ ": union replay requires serde_protocol.checkpoint and serde_protocol.restore");
        return @TypeOf(P.checkpoint(@as(*D, undefined)));
    }
    return D;
}
pub fn checkpoint(d: anytype) Checkpoint(Backend(@TypeOf(d))) {
    const D = Backend(@TypeOf(d));
    if (@hasDecl(D, "serde_protocol")) return D.serde_protocol.checkpoint(d);
    return d.*;
}
pub fn restore(d: anytype, saved: Checkpoint(Backend(@TypeOf(d)))) void {
    const D = Backend(@TypeOf(d));
    if (@hasDecl(D, "serde_protocol")) D.serde_protocol.restore(d, saved) else d.* = saved;
}

pub fn sizeHint(access: anytype) ?usize {
    const A = Backend(@TypeOf(access));
    if (@hasDecl(A, "serde_protocol")) {
        if (@hasDecl(A.serde_protocol, "sizeHint")) return A.serde_protocol.sizeHint(access);
        return null;
    }
    if (@hasField(A, "remaining")) return access.remaining;
    if (@hasField(A, "items")) return access.items.len;
    return null;
}

pub fn missingField(access: anytype, name: []const u8) void {
    const A = Backend(@TypeOf(access));
    if (@hasDecl(A, "serde_protocol") and @hasDecl(A.serde_protocol, "missingField"))
        A.serde_protocol.missingField(access, name);
}
