# Exchange a telemetry batch

Encode a warehouse sensor batch for MessagePack and Erlang ETF consumers, validate both decoded messages, and compare all fields.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-binary-interchange
```

## Input and output

The batch in `main.zig` has a schema version, device ID, sequence number, Unix
timestamp in seconds, and four readings with explicit units. A failed pressure
sensor has a null value instead of a numeric sentinel that could be mistaken
for a measurement.

Stdout contains the canonical JSON batch. Stderr reports byte counts for this
payload and `4 readings, 2 alerts`. Both binary decodes must match the entire
original value. Size differences apply to this fixture only; the program is
not a benchmark and does not assume binary output is always smaller.

## Patterns to reuse

The same structs work with `msgpack` and `etf`. `receive` returns a managed parse
result, using `errdefer` to clean it up if application validation fails. It
rejects unsupported versions, empty batches/IDs, missing successful readings,
non-finite measurements, and failed readings with numeric values.

Payload slices stand in for individual queue messages. The program does not
connect to a broker or Erlang node. Transport framing, acknowledgements, replay
handling, and compatibility policy for future versions belong to the caller.
For actual Erlang interoperability checks, see `zig build interop` in the root
build (requires Erlang/OTP 29).

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
