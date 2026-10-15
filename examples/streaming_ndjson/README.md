# Filter an application log stream

Read newline-delimited JSON from a file and emit warning/error records as another NDJSON stream.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-streaming-ndjson
```

## Input and output

[requests.ndjson](requests.ndjson) is read at runtime through a 4 KiB reader
buffer. It contains a blank line, one malformed timing field, and a final record
without a trailing newline. The example emits two alert records on stdout and
reports this summary on stderr:

```text
Records: 5 valid, 1 rejected, 2 alerts
```

```sh
zig build example-streaming-ndjson > /tmp/alerts.ndjson
```

Append or edit records in the fixture to experiment. A malformed JSON record is
reported and skipped; file-read and allocation failures terminate the program.
Missing `request_id` and `duration_ms` become null in the serialized alerts.

## Patterns to reuse

`StreamingDeserializer` consumes complete lines from a file reader. Unlike
loading an entire log into a slice, this retains only the reader buffer, the
reusable line buffer, and the current decoded record. `freeAllocated` releases
owned strings after each iteration; no arena grows for the whole log.

The reader's 4 KiB buffer is not a maximum record size. The helper grows its line
buffer as needed and retains that capacity; this example assumes trusted local
logs with reasonably sized lines. A malformed line is safe to skip because
`next` has already consumed its line before JSON parsing starts.

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
