# Contributing to serde.zig

Thank you for your interest in contributing! This document covers the basics.

## Development Setup

You need [Zig 0.15.0](https://ziglang.org/download/) or later.

```sh
git clone https://github.com/OrlovEvgeny/serde.zig.git
cd serde.zig
zig build test
```

## Code Style

Run `zig fmt` before committing. The CI enforces formatting.

```sh
zig fmt src/ build.zig
```

Use `const` by default. Prefer explicit types over `auto`-style inference when it improves readability. Follow the patterns already present in the codebase.

## Making Changes

1. Fork the repository.
2. Create a feature branch from `master`.
3. Make your changes with tests.
4. Ensure all tests pass: `zig build test`.
5. Ensure formatting is clean: `zig fmt --check src/ build.zig`.
6. Open a pull request against `master`.

## Commit Messages

Use concise, imperative-style messages:

```
feat: add CBOR format support
fix: handle empty structs in XML deserializer
docs: clarify union tagging in README
refactor: deduplicate scanner logic
```

Prefix with a label when it makes sense: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.

## Adding a New Format

Each format lives in `src/formats/<name>/` and must provide:

- `mod.zig` — public API (`toSlice`, `fromSlice`, `toWriter`, `fromReader`, schema-aware variants)
- `serializer.zig` — a type implementing the `Serializer` interface from `src/core/interface.zig`
- `deserializer.zig` — a type implementing the `Deserializer` interface

Both interfaces are verified at comptime by `isSerializer` / `isDeserializer` in `src/core/interface.zig`.

Add the new format to:
- `src/root.zig` — import and re-export
- `build.zig` — add fuzz target if applicable
- `README.md` — add to the Formats table

## Adding Tests

- Unit tests go in the same file as the code they test (using `test` blocks).
- Cross-format roundtrip tests go in `test/roundtrip_test.zig`.
- Stress and edge-case tests go in `test/` with descriptive file names.
- Fuzz harnesses go in `test/fuzz_<format>.zig`.

## Reporting Issues

When filing a bug, please include:

- Zig version (`zig version`)
- Minimal reproducible example
- Expected vs actual behavior

## License

By contributing, you agree that your changes will be licensed under the [MIT License](LICENSE).
