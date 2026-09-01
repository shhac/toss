# toss

A fast dice rolling CLI written in Zig.

**Website:** [toss.paulie.app](https://toss.paulie.app/)

![Demo](assets/demo.gif)

## Installation

### Homebrew (macOS/Linux)

```bash
brew install shhac/tap/toss
```

### From Source

```bash
zig build -Doptimize=ReleaseSmall
# Binary will be at zig-out/bin/toss
```

### Pre-built Binaries

Download from [Releases](https://github.com/shhac/toss/releases).

## Usage

```bash
# Basic rolls
toss 2d6 1d20

# Modifiers: keep highest, drop lowest
toss 4d6k3          # Roll 4d6, keep highest 3 (D&D ability scores)
toss 2d20kh1        # Advantage
toss 2d20kl1        # Disadvantage

# Exploding dice (quote to prevent shell expansion)
toss '1d6!'         # Explode on max (Savage Worlds)
toss '2d10!!'       # Compound explode
toss '1d6!p'        # Penetrating explode

# Reroll (quote expressions with < or >)
toss 2d6r1          # Reroll 1s (continuous)
toss '2d6ro<=2'     # Reroll once if ≤2 (Great Weapon Fighting)

# Arithmetic
toss 2d6+5          # Add modifier
toss 1d20+1d4+3     # Multiple dice and numbers

# Special dice
toss d%             # Percentile (d100)
toss 4dF            # Fudge/Fate dice (-1, 0, +1)

# Combined
toss '4d6!r1k3+5'   # Explode, reroll 1s, keep best 3, add 5

# Aligned output (labels padded for column alignment)
toss 1d6 2d100
# [__1d6]   3
# [2d100]  42  87

# Options
toss --seed 42 2d6      # Reproducible rolls
toss --show-seed 1d20   # Print the seed used (to stderr)
toss --show-rerolls 2d6r1  # Show what each die was rerolled from
toss --no-labels 2d6    # Omit the [expr] prefix
toss --result-only 4d6k3   # Print only the total
```

Dropped dice are struck through in a terminal, and written as `~4~` when
output is piped or `NO_COLOR` is set:

```bash
toss 4d6k3 | cat
# [4d6k3] 6 5 4 ~1~ = 15
```

## Exit status

`0` on success, `1` if any expression fails to parse or evaluate. Rolls that
did succeed are still printed, so a partial failure both reports the good rows
and signals failure:

```bash
toss 2d6 nonsense && echo "all ok"   # prints the 2d6 row, then exits 1
```

## Features

- **Fast**: Single binary, no runtime dependencies
- **Small**: ~30KB release binary
- **Reproducible**: Optional `--seed` for deterministic rolls
- **Scriptable**: Results to stdout, diagnostics to stderr
- **Colored output**: Row colors cycle (respects `NO_COLOR`)
- **Cross-platform**: Linux, macOS, and Windows

### Dice Notation

| Feature | Syntax | Example |
|---------|--------|---------|
| Basic | `NdS` | `2d6`, `d20` |
| Percentile | `d%` | `d%`, `2d%` |
| Fudge/Fate | `dF` | `4dF` |
| Keep highest | `kN`, `khN` | `4d6k3` |
| Keep lowest | `klN` | `2d20kl1` |
| Drop lowest | `dN`, `dlN` | `4d6d1` |
| Drop highest | `dhN` | `4d6dh1` |
| Exploding | `!` | `1d6!` |
| Compound | `!!` | `1d6!!` |
| Penetrating | `!p` | `1d6!p` |
| Reroll | `rN` | `2d6r1` |
| Reroll once | `roN` | `2d6ro<=2` |
| Arithmetic | `+`, `-`, `*`, `/` | `2d6+5` |

See [SYNTAX.md](SYNTAX.md) for full documentation.

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
