# Application author guide

Use [the complete managed JSON example](../examples/managed_json/main.zig):
`zig build example-managed-json`. Connect the `serde` dependency as shown in the
README. Choose a format using the [capability matrix](capabilities.md).

Prefer `format.fromSliceManaged(T, allocator, input)`. Access `.value` and defer
`.deinit()`. Ordinary `toSlice` output is separately owned: defer
`allocator.free(bytes)`. `fromSliceManagedSchema` adds an external schema without
modifying a dependency's types. All nine formats have managed parsing helpers.

Use a caller-owned arena with `fromSlice` if several results should share one
lifetime. `fromSlice` alone does not provide a destructor. For ordinary inferred
values you can use `serde.core.freeAllocated`, or `freeAllocatedSchema` when
schema defaults are involved. A managed result is usually simpler, especially
with custom adapters that retain their allocator.

Borrowed JSON strings point into the original input and cannot outlive it.
Escaped strings are rejected by borrowed parsing, not silently copied. Containers
and custom hooks can still allocate. Never pass a borrowed result to the ordinary
owning `freeAllocated` helper; use an arena for its allocated containers and keep
the input alive. Borrowing is not a general lifetime checker.

## JSON diagnostics

```zig
var path_buffer: [256]u8 = undefined;
var diagnostics = serde.json.Diagnostics.init(&path_buffer);
var result = serde.json.fromSliceManagedWithDiagnostics(
    User, allocator, input, .{}, &diagnostics,
) catch |err| {
    std.debug.print("{s} at {s}, byte {d}, {d}:{d}\n", .{
        @errorName(err), diagnostics.path, diagnostics.byte_offset,
        diagnostics.line, diagnostics.column,
    });
    return err;
};
defer result.deinit();
```

`original_error` is optional and remains null on success. `path` is a JSON pointer:
`/users/2/age`; `~` becomes `~0`, `/` becomes `~1`. The empty path denotes the root.
`byte_offset` is zero-based. `line` and `column` are one-based; columns count UTF-8
bytes, not display characters. LF starts a new line; a CR in CRLF counts as a
byte on the preceding line. `expected` and `actual` provide context when known.
For missing fields, `expected` contains the missing wire name.

Type errors point to the start of the value. Syntax errors point to the scanner's
problem byte; missing input points to the end. A missing field points at the
closing brace of its object. Unknown and duplicate fields identify the actual
key. Failed untagged alternatives are discarded; if all fail, the path is the
union's own path. Initialize another deserializer to reuse the diagnostics.

The path is copied into your buffer, so it survives freeing input and decoded
keys. A short or empty buffer sets `path_truncated`, preserves a byte prefix, and
never replaces the original error. Truncation can split a UTF-8 code point or a
pointer escape. The buffer must outlive inspection of the diagnostics and must not overlap the input.
The diagnostic state itself makes no heap allocations; parsing values and creating
a managed arena still allocate normally.

For schemas and external adapters, create
`serde.json.DeserializerWithDiagnostics.init(input, options, &diagnostics)`, call
`serde.deserializeSchema(T, allocator, &d, schema, adapters)` (or
`deserializeWith`), then `try d.finish()` to reject trailing input. Use an arena,
or release the returned value if `finish` fails. Recursive hooks must deserialize
through the supplied `d` to retain context.

## Choosing between serde and std.json

For a JSON-only application with ordinary structs and no shared cross-format
adapters, `std.json` may cover the whole task with no extra dependency. serde is
useful when type mappings must work across several formats, external schemas
must override third-party types, or libraries need a common extension contract.
Their options and behavior are not interchangeable; test a migration against real
input, particularly number limits, missing fields, defaults and ownership.
