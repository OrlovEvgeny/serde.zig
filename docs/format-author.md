# Format author guide

Read the [extension contract](extension-contract.md), then the independent
[tagged event text backend](../test/packages/format_author/format.zig) and its
[consumer tests](../test/packages/format_author/main.zig). Run `zig build test` in
that package. `python3 test/check_package.py` repeats the test with only files
listed in the package allowlist. The educational format is not a tenth supported
format and is not intended for untrusted production input.

The backend stores `document`, `offset`, `source`, and `destination` rather than
reproducing built-in state fields. Its explicit `serde_protocol` checkpoint is
just a cursor. The tests exercise the full structural checks, nested containers,
strings containing newlines, exact output, and untagged union replay.

1. Define your supported root types and number/key limits first. Choose whether
   you parse from a slice, a prebuilt tree, or a reader. A method declaration does
   not guarantee a format can represent every Zig type.
2. Implement scalar operations and `Error`, preserving allocation errors.
3. Implement containers and access objects with core recursion. On success,
   consume exactly one value; on failure, free partially built output.
4. Declare explicit borrowing, length hints, and replay capabilities. Omit replay
   if your source cannot rewind. Keep input and parent objects alive while access
   objects use them. Never guess ownership from an unrelated wrapper field.
5. Add the opt-in structural assertions, concrete tests for supported profiles,
   allocation failure tests, malformed-input tests, and format-specific interop.

Reader convenience functions in existing formats buffer their input; they are not
a streaming contract. A new streaming format can implement supported shapes, but
v1.2 does not implement streaming replay for union layouts that need it.
For a length-prefixed format, implement paired known-length containers and verify
counts; treat sequence length hints as untrusted until input is validated.

Keep the format in its own Zig package and depend on the public `serde` module.
Do not import `src/core/*.zig` by relative path. The educational package and
`serde.testing` demonstrate separate integration and mapping tests. Structural
assertions instantiate representative generic calls; use your own tests for
other widths, custom hooks, wire conformance and cleanup.
