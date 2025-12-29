# toss

A fast, tiny dice rolling CLI written in Zig.

## Installation

```bash
# Build from source
zig build -Doptimize=ReleaseSmall

# Binary will be at zig-out/bin/toss
```

## Usage

```bash
# Roll dice
toss 2d6 1d4
# [2d6] 4 6
# [1d4] 3

# Seeded RNG (reproducible rolls)
toss --seed 1234 2d6
# [2d6] 5 1

# Show the seed used (outputs to stderr)
toss --show-seed 1d20
# [seed] 8196891979282801990
# [1d20] 14

# Help
toss --help
```

## Features

- **Fast**: Single binary, no runtime dependencies
- **Tiny**: ~75KB release binary
- **Reproducible**: Optional `--seed` for deterministic rolls
- **Scriptable**: Results to stdout, diagnostics to stderr
- **Standard notation**: Supports `NdS` format (e.g., `2d6`, `1d20`, `d4`)

## Build Commands

```bash
# Development build
zig build

# Run directly
zig build run -- 2d6 1d4

# Run tests
zig build test

# Release builds
zig build -Doptimize=ReleaseSmall   # Smallest binary (~75KB)
zig build -Doptimize=ReleaseFast    # Fastest execution
zig build -Doptimize=ReleaseSafe    # With safety checks
```

## License

MIT
