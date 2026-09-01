# Changelog

All notable changes to this project are documented here.

## [0.6.0]

### Seeded rolls changed

Two dice bugs are fixed in this release, and both change what a given
`--seed` produces. If you rely on a seed reproducing an exact roll, expect
different results from 0.5.1 for expressions using `!!` or rerolls on `d1`:

- **Compound explosions (`!!`) never chained.** A die that rolled its maximum
  exploded once and stopped, and was not marked as exploded in the output.
  `1d6!!` now keeps compounding while it rolls the maximum, as the notation
  means, and shows the `*` marker.
- **Rerolling a `d1` looped pointlessly.** `shouldReroll` ignored the die size
  despite documenting that it would not reroll a `d1`, so `2d1r1` burned 100
  rolls and printed a run of junk reroll history. Fudge dice still reroll.

Every other expression rolls exactly as it did in 0.5.1.

### Added

- Dropped dice are struck through on a terminal instead of being wrapped in
  tildes. Piped output and `NO_COLOR` keep `~N~` unchanged, so anything
  parsing this output is unaffected.
- Parse errors say which character failed and where:
  `Unexpected character in '2d10!!!' (at position 7: '!')`.
- Continuous integration on every push: build, tests, formatting, and
  cross-compilation of all five release targets.

### Fixed

- **Any failing expression now exits `1`.** `toss 1d6/0` printed an error and
  exited `0`, as did too many dice and arithmetic overflow, so scripts could
  not tell a bad roll from a good one. Rolls that succeed are still printed.
- Malformed input that never looked like dice notation now reports the
  expected shape rather than a lexer-level error, e.g. `toss ad6` explains
  `expected NdN`.

### Internal

- Ported to Zig 0.16 (`std.Io`), which is now the minimum supported version.
- The test suite ran **zero tests** while reporting success, because Zig only
  discovers tests in the root source file. All 185 tests now actually run.
- The version is read from `build.zig.zon` alone rather than being repeated in
  the binary and the release script.
