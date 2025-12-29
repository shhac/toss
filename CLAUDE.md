# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`toss` is a dice rolling CLI written in Zig. It parses dice notation (e.g., `2d6`, `1d4`) and outputs roll results with colored, aligned output.

## Build Commands

```bash
# Build the project
zig build

# Build and run
zig build run -- 2d6 1d4

# Run tests
zig build test

# Build in release mode
zig build -Doptimize=ReleaseSmall

# Cross-platform release build
./scripts/release.sh
```

## Usage Examples

```bash
# Roll multiple dice
toss 2d6 1d4

# Seeded RNG (reproducible rolls)
toss --seed 1234 1d6

# Show the seed used (outputs seed to stderr)
toss --show-seed 1d6

# Mixed dice with aligned output
toss 1d6 2d100
# [1d__6]   2
# [2d100]  35   5

# Disable colors
NO_COLOR=1 toss 2d6

# Version
toss --version

# Help
toss --help
```

## Architecture

The CLI follows standard Zig patterns:
- `src/main.zig` - Entry point, argument parsing, output formatting, colors
- `src/dice.zig` - Dice notation parsing (`2d6` -> `{count: 2, sides: 6}`)
- `src/rng.zig` - Seedable RNG wrapper with OS entropy fallback
- `scripts/release.sh` - Cross-platform release build script

### Key Features
- Dice notation: `<count>d<sides>` format (e.g., `2d6` = roll two 6-sided dice)
- Uses Zig's `std.Random.DefaultPrng` with optional seeding
- OS entropy via `std.posix.getrandom()` for true random seeds
- TTY detection via `std.io.tty.Config.detect()` for colored output
- Respects `NO_COLOR` environment variable
- Results to stdout, diagnostics (seed, errors) to stderr
- Aligned output with underscore padding in labels for awk compatibility
