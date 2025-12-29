# toss

A fast, tiny dice rolling CLI written in Zig.

## Installation

```bash
# Build from source
zig build -Doptimize=ReleaseSmall

# Binary will be at zig-out/bin/toss
```

Or download a pre-built binary from [Releases](https://github.com/shhac/toss/releases).

## Usage

```bash
# Roll dice
toss 2d6 1d4
[2d6] 4 6
[1d4] 3

# Seeded RNG (reproducible rolls)
toss --seed 1234 2d6
[2d6] 5 1

# Show the seed used (outputs to stderr)
toss --show-seed 1d20
[seed] 8196891979282801990
[1d20] 14

# Mixed dice with aligned output
toss 1d6 2d100
[1d__6]   2
[2d100]  35   5

# Version
toss --version

# Help
toss --help
```

## Features

- **Fast**: Single binary, no runtime dependencies
- **Tiny**: 28-76KB release binary (platform dependent)
- **Reproducible**: Optional `--seed` for deterministic rolls
- **Scriptable**: Results to stdout, diagnostics to stderr
- **Colored output**: Row colors cycle through color groups (respects `NO_COLOR`)
- **Aligned output**: Numbers padded for clean columns when mixing dice types
- **Standard notation**: Supports `NdS` format (e.g., `2d6`, `1d20`, `d4`)
- **Cross-platform**: Linux, macOS, and Windows builds

## Disabling Colors

```bash
NO_COLOR=1 toss 2d6 1d4
```

## Build Commands

```bash
# Development build
zig build

# Run directly
zig build run -- 2d6 1d4

# Run tests
zig build test

# Release builds
zig build -Doptimize=ReleaseSmall   # Smallest binary
zig build -Doptimize=ReleaseFast    # Fastest execution
zig build -Doptimize=ReleaseSafe    # With safety checks

# Cross-platform release (builds all targets)
./scripts/release.sh
```

## License

MIT
