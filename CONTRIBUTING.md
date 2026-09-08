# Contributing to serde.zig

Thank you for your interest in contributing! This document covers the basics.

## Development Setup

You need [Zig 0.15.2](https://ziglang.org/download/) or later. CI also runs
against Zig master, which currently tracks 0.17 development builds; see the
Compatibility section of the README.

```sh
git clone https://github.com/OrlovEvgeny/serde.zig.git
cd serde.zig
zig build test
```

The repository also includes [mise](https://mise.jdx.dev/) configs for the
supported Zig versions:

```sh
mise install
mise -E zig15 install
mise -E zig16 install
mise -E zig17 install

mise run ci
mise -E zig15 run ci
mise -E zig16 run ci
mise -E zig17 run ci
```

`mise.toml` defaults to Zig 0.16.0. The `zig15`, `zig16`, and `zig17`
environments select Zig 0.15.2, 0.16.0, and Zig master/0.17-dev explicitly.

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

Length-prefixed formats may additionally declare `beginArrayLen` / `beginStructLen`.
The core calls them instead of `beginArray` / `beginStruct` whenever the element
count is known up front, so the header can be written before the payload instead
of buffering it. Declare both or neither, and note the contract: the caller emits
exactly the declared number of elements, so a serializer should verify the count
under `std.debug.runtime_safety`. See `hasKnownLengthContainers` in
`src/core/interface.zig`.

Add the new format to:
- `src/root.zig` — import and re-export
- `build.zig` — add fuzz target if applicable
- `README.md` — add to the Formats table

## Adding Tests

- Unit tests go in the same file as the code they test (using `test` blocks).
- Cross-format roundtrip tests go in `test/roundtrip_test.zig`.
- Stress and edge-case tests go in `test/` with descriptive file names.
- Fuzz harnesses go in `test/fuzz_<format>.zig`.

## Releasing

The version appears in two places, and the release workflow checks both against
the tag before publishing:

- `.version` in `build.zig.zon`
- the tarball URL in the README install section

Bump both, commit, and only then tag:

```
git tag vX.Y.Z
git push origin vX.Y.Z
```

Tagging first fails the release, because the workflow validates the tagged tree.

## Reporting Issues

When filing a bug, please include:

- Zig version (`zig version`)
- Minimal reproducible example
- Expected vs actual behavior

## License

By contributing, you agree that your changes will be licensed under the [MIT License](LICENSE).
