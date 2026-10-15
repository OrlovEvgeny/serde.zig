# Expose a public configuration view

Load a dependency-owned type from kebab-case TOML and serialize a redacted camelCase API view without modifying that type.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-schema-override
```

## Input and output

[service.toml](service.toml) is read at runtime with a 64 KiB limit. Its
`auth-token` is a dummy credential. The output contains:

```json
{"name":"shipping-client","maxRetries":5,"baseUrl":"https://shipping.example.com","logLevel":"info"}
```

The actual JSON is pretty-printed on stdout. A short load message goes to stderr.
Neither output includes the token. The program does not rewrite the file or
make network requests.

## Patterns to reuse

`RawConfig` has no `serde` declaration. `fromSliceManagedSchema` applies the
kebab-case schema while parsing; `toSliceWithSchema` applies camelCase and
`SkipMode.always` for the API view. The full config stays available to the
application until `deinit`.

Validation requires a name, a nonempty token, an `https://` URL prefix, and at
most 10 retries. It is an example policy, not a complete URL validator. Redaction
belongs to the output schema: serializing with the default schema would expose
the token, so use the public schema consistently for this view.

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
