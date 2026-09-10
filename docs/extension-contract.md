# Extension contract (v1.2)

Import `const serde = @import("serde");`. The package is one dependency; its generic
engine is `serde.core`. Type authors and format authors can work independently.
`Kind` and `Value` retain their existing representations in this release.

## Dispatch and the data model

`serialize(T, value, &s, adapters)` and `deserialize(T, allocator, &d, adapters)`
prefer `zerdeSerialize` / `zerdeDeserialize`, then the first matching external
adapter, then reflection. `serializeSchema` / `deserializeSchema` take `schema`
before `adapters`; explicit schema options override `T.serde`. Hooks bypass schema
inference. Nested adapters propagate through fields, optional values, pointers,
sequences, maps and union payloads. Flatten applies to structs, not maps.

The typed engine distinguishes booleans, signed/unsigned integers, floats, strings,
bytes, arrays, slices, optionals, structs, tuples, enums, tagged unions, void,
single pointers, maps and custom types. Format support is a separate question.
`Value` is a JSON-like dynamic tree with string keys and i64/u64/f64 numbers;
it is not a lossless intermediary for every typed operation.

## Serializer

A full serializer `S` declares `pub const Error = error{...}` and these public
methods (receiver `self: *S`, omitted below):

| Method | Remaining parameters | Result |
| --- | --- | --- |
| `serializeBool` | `value: bool` | `Error!void` |
| `serializeInt`, `serializeFloat` | `value: anytype` | `Error!void` |
| `serializeString` | `value: []const u8` | `Error!void` |
| `serializeNull`, `serializeVoid` | none | `Error!void` |
| `beginArray` | none | `Error!ArrayContainer` |
| `beginStruct` | none | `Error!StructContainer` |

An array container is itself a full serializer and has `end() Error!void`. Each
scalar or nested container is an element. A struct container declares `Error`,
`serializeField(comptime key: []const u8, value: anytype) Error!void`,
`serializeEntry(key: anytype, value: anytype) Error!void`, and `end() Error!void`.
It serializes nested values through `serde.serialize`; calling scalar methods
alone loses user hooks. Containers must handle values whose only supported
operation is a custom serialization hook, including the core's adapter wrappers.

Values and strings passed to serialization methods may come from a hook's local
scratch buffer. Consume them during the call or keep an owned copy; do not retain
borrowed pointers after returning.

Call `end` exactly once on success. The core calls optional container `deinit()`
on both success and failure; it must release temporary resources without adding
output or freeing a completed result. A failed backend may have partially written
output. Discard that output; the core does not roll it back.

Optional `serializeBytes` receives bytes instead of a string. Optional
`beginArrayLen(len)` and `beginStructLen(len)` must be declared together. Their
containers have the same respective contracts. The caller emits exactly `len`
elements/entries; implementations should verify the count under runtime safety.
Lengths avoid buffering in formats with length prefixes.

## Deserializer and access objects

A full deserializer `D` declares `Error`. Receivers below are `self: *D`:

| Method | Remaining parameters | Result |
| --- | --- | --- |
| `deserializeBool` | none | `Error!bool` |
| `deserializeInt`, `deserializeFloat` | `comptime T: type` | `Error!T` |
| `deserializeString` | `allocator: std.mem.Allocator` | `Error![]const u8` |
| `deserializeVoid` | none | `Error!void` |
| `deserializeOptional` | `comptime T: type, allocator` | `Error!?T` |
| `deserializeEnum` | `comptime T: type` | `Error!T` |
| `deserializeUnion` | `comptime T: type, allocator` | `Error!T` |
| `deserializeStruct` | `comptime T: type` | `Error!MapAccess` |
| `deserializeSeqAccess` | none | `Error!SeqAccess` |
| `raiseError` | `err: anyerror` | `Error` |

`deserializeOptional` receives the child type, not the optional type. For a present
value it must recurse through `serde.deserialize`. `deserializeUnion` implements
the default external-tag representation; schemas and other tagging layouts use
the generic engine. Optional `deserializeBytes(allocator)` reads byte payloads.
The old `deserializeSeq(T, allocator)` convenience method is retained by built-ins
but is not required by the current core.

A map access object declares `Error` and provides:

- `nextKey(allocator) Error!?[]const u8`: consume the next key, or consume the
  object terminator and return null. Keys in the generic read path are strings.
- `nextValue(comptime T: type, allocator) Error!T`: read the value for that key
  through the generic engine. Call once per key, or call `skipValue()` instead.
- `skipValue() Error!void`: consume the complete value, including nested syntax.
- `raiseError(anyerror) Error`: map generic errors into the backend error set.
- Optional `freeKey(key, allocator) void`: release allocated keys. Without this
  method the core assumes keys need no release. A key remains valid until released.

A sequence access object declares `Error` and provides
`nextElement(comptime T: type, allocator) Error!?T`. It consumes the terminator on
null. Recursion must use the generic engine. Do not read an exhausted access
object again. Parent deserializers must outlive their access objects; do not move
them while access objects are in use. Failure may consume input. Only an explicit
checkpoint/restore pair promises replay.

Preserve `OutOfMemory`. Generic errors include `WrongType`, `UnexpectedToken`,
`UnexpectedEof`, `MissingField`, `DuplicateField`, `UnknownField`, `Overflow`, and
`WithFailed`. Backends can normalize unsupported codes through `raiseError`.
A hook's return type should use the backend's error set to avoid widening it.

## Ownership

Allocated strings, pointers, sequences and map storage transfer to the returned
value. Partial results must be released on failure using the supplied allocator.
Borrowed slices and schema/default literals are not owned. `Parsed(T)` owns an
arena at a stable address, including allocators retained by managed maps. It can
be moved, but must not be copied and deinitialized twice.

A hook owns cleanup for allocations it makes before failing. Use
`serde.core.releaseString(d, allocator, text)` for a temporary string returned by
`d.deserializeString`. It frees owned strings and retains views into the backend's
borrowed input. On success, transfer returned storage to the value or release it;
do not keep freed temporaries. Managed parsing releases all arena allocations at
once; it does not call arbitrary user destructors or close external resources.

## Optional `serde_protocol`

Backend and access types may declare this public namespace. Its functions take
the concrete backend/access pointer as their first argument:

| Capability | Signature | Meaning when absent in the namespace |
| --- | --- | --- |
| Borrowing | `borrowedInput(*const D) ?[]const u8` | all returned strings are owned |
| Sequence hint | `sizeHint(*const A) ?usize` | unknown remaining length |
| Replay | `checkpoint(*const D) Checkpoint`, `restore(*D, Checkpoint) void` | replay unavailable |
| Missing field context (map) | `missingField(*M, name: []const u8) void` | no extra context |
| Failure context | `failure(*D, err: anyerror) void` | no extra context |

Capabilities are explicit once the namespace exists: the core stops inspecting
fields for borrowing and length hints. Without the namespace, historical
`borrow_strings`, `scanner` / `input`, `parent` / `deser`, `remaining` / `items`
inference and whole-value replay remain for compatibility. New backends should
use the namespace and choose their own state layout.

Hints are untrusted. The core caps eager allocation at approximately 64 KiB of
elements (at least one element); parsing still verifies every element. A checkpoint
must restore every cursor and side effect relevant to parsing, including
speculative diagnostics. It must not invalidate successful allocations returned
before the checkpoint. Checkpoints are lightweight values; the core does not
allocate or destroy them. Declare checkpoint and restore together.

Untagged unions, internal/adjacent tags, and externally tagged unions with name
or adapter overrides can require replay. An opted-in backend without replay
receives a targeted compile-time error for such operations. There is no streaming
union parser in v1.2.

`missingField` is called before `raiseError(MissingField)` with the expected wire
name, including union discriminator/content names. `failure` observes an error
escaping a generic deserialize call, including custom hooks. It must not replace
the error. The JSON implementation also uses `unionVariant` internally when
sharing its ordinary external union parser; third-party backends do not need it.

## Checking an implementation

Call `comptime serde.core.assertSerializer(S)` / `assertDeserializer(D)` explicitly.
They check declarations, representative method signatures, and container/access
results. They do not prove all generic instantiations, format semantics, or error
cleanup. Existing `isSerializer` / `isDeserializer` retain their historical,
permissive declaration checks and are not upgraded automatically.

Restricted profiles such as CSV row deserializers, TOML root tables and ZON's
unsupported default union reader cannot satisfy every full-interface probe.
Test their supported shapes separately; do not advertise full model support.
The independent [format package](../test/packages/format_author/format.zig) is an
executable example of the full structural contract with an explicit protocol.
