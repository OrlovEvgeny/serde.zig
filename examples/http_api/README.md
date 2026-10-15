# Decode an order webhook

Turn a tagged order event into a public acknowledgement, using the serialization portion of an HTTP handler.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-http-api
```

## Input and output

[webhook.json](webhook.json) is read at runtime with a 64 KiB limit. The included
`shipped` event produces `status: "tracking_updated"`, order ID `ord-1042`, and
tracking number `NL-38492716`.

Try these other request bodies:

```json
{"event_type":"created","order_id":"ord-1042","total_cents":2995}
```

```json
{"event_type":"cancelled","order_id":"ord-1042","reason":"customer request"}
```

The JSON response goes to stdout. A simulated HTTP 202 status goes to stderr.
There is no listening server, persistence, signature verification, or event
queue here: a real handler supplies authenticated input and maps failures to
HTTP responses. The request ID and Unix timestamp in seconds are fixed so
runs are repeatable.

## Patterns to reuse

An internally tagged union dispatches on `event_type`. Each variant is
validated before constructing a response. Response fields use camelCase,
metadata is flattened into the response, null tracking numbers are omitted,
and `internal_token` is always excluded. Output is serialized while the managed
request result is alive because acknowledgement strings borrow from it.

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
