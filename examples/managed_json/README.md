# Validate independent queue messages

Inspect email jobs one at a time, report malformed input, and continue with the next job.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-managed-json
```

## Input and output

[job.json](job.json) and [invalid-job.json](invalid-job.json) are embedded at
compile time, followed by a third valid message in `main.zig`. Edit either
fixture and rerun the build to try another payload.

The invalid job uses a string for `retry.max_attempts`. Diagnostics identify
`/retry/max_attempts` and its line and column. The final summary is:

```text
Jobs: 2 accepted, 1 rejected
```

All output is diagnostic text on stderr. The expected rejection does not make
the program fail; allocator failures still propagate. Empty IDs, recipient
lists, and zero retry counts are rejected separately after parsing. This is a
local consumer example; it does not connect to a queue or send email.

## Patterns to reuse

`fromSliceManagedWithDiagnostics` returns one owner for the job, recipient slice,
and recipient strings. Each invocation releases its result before the next job.
A caller-provided buffer holds the diagnostic JSON pointer. Missing
`max_attempts` uses the Zig default of 3; business validation remains explicit.

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
