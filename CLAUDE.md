# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`toss` is a dice rolling CLI written in Zig. It parses dice notation (e.g., `2d6`, `1d4`) and outputs roll results.

## Build Commands

```bash
# Build the project
zig build

# Build and run
zig build run -- 2d6 1d4

# Run tests
zig build test

# Build in release mode
zig build -Doptimize=ReleaseSafe
```

## Usage Examples

```bash
# Roll multiple dice
toss 2d6 1d4

# Seeded RNG (reproducible rolls)
toss --seed 1234 1d6

# Show the seed used (outputs seed to stderr)
toss --show-seed 1d6

# Help
toss --help
```

## Architecture

The CLI follows standard Zig patterns:
- `src/main.zig` - Entry point, argument parsing, output formatting
- `src/dice.zig` - Dice notation parsing (`2d6` -> `{count: 2, sides: 6}`)
- `src/rng.zig` - Seedable RNG wrapper with OS entropy fallback
- Dice notation parsing: `<count>d<sides>` format (e.g., `2d6` = roll two 6-sided dice)
- Uses Zig's `std.Random` for RNG with optional seeding
- `--show-seed` outputs to stderr to keep stdout clean for scripting
