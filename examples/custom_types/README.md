# Serialize an artifact manifest

Create and verify a manifest with a large numeric ID and a SHA-256 checksum, using custom serialization hooks.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-custom-types
```

## Input and output

`main.zig` contains a small CSV invoice payload. It hashes those exact bytes,
serializes the manifest, parses it, and verifies the ID, size, and checksum.
The JSON manifest goes to stdout; a verification message goes to stderr.

The ID is `"9223372036854775807"` on the wire, preserving its exact value for
JavaScript clients. The checksum is a 64-character lowercase hexadecimal
string computed from the payload, rather than placeholder bytes.

## Patterns to reuse

`StringId` encodes a `u64` as a decimal string. `Sha256Digest` uses a fixed
32-byte array internally and validates the length and hex digits on input.
The hooks return the backend's declared error set and use `raiseError` to
translate invalid input. `releaseString` releases temporary owned strings
while respecting borrowed input.

A managed parse result owns the manifest filename. The checksum array needs
no separate allocation. This demonstrates checksum transport and consistency
checking; it does not implement cryptographic signatures or artifact storage.

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
