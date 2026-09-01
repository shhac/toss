//! Command-line surface: the flags `toss` accepts and the help text it prints.

const std = @import("std");

pub const version = @import("build_options").version;

pub const help_text =
    \\toss - A dice rolling CLI
    \\
    \\Usage: toss [OPTIONS] <DICE>...
    \\
    \\Arguments:
    \\  <DICE>...           Dice expressions (e.g., 2d6, 4d6k3, 2d6+5)
    \\
    \\Options:
    \\  -s, --seed <NUM>    Seed for reproducible rolls
    \\      --show-seed     Output the seed used to stderr
    \\      --show-rerolls  Show reroll history (e.g., 1,3 means rolled 1, rerolled to 3)
    \\      --no-labels     Omit the [expr] label prefix
    \\      --result-only   Only show the final total (no individual dice)
    \\  -h, --help          Display this help message
    \\  -V, --version       Show version information
    \\
    \\Dice notation:
    \\  NdS                 Roll N dice with S sides (e.g., 2d6)
    \\  dS                  Roll 1 die (e.g., d20)
    \\  d%                  Percentile die (d100)
    \\  dF                  Fudge die (-1, 0, +1)
    \\
    \\Modifiers:
    \\  k, kh<N>            Keep highest N dice (e.g., 4d6k3)
    \\  kl<N>               Keep lowest N dice
    \\  d, dl<N>            Drop lowest N dice (e.g., 4d6d1)
    \\  dh<N>               Drop highest N dice
    \\
    \\Exploding:
    \\  !                   Explode on max value (e.g., 1d6!)
    \\  !!                  Compound explode (adds to same die)
    \\  !p                  Penetrating explode (-1 per explosion)
    \\  !>N, !<N, !=N       Explode on threshold (e.g., 1d6!>4)
    \\
    \\Reroll:
    \\  r, r<N>             Reroll on value (default: 1s, e.g., 2d6r1)
    \\  ro, ro<N>           Reroll once (e.g., 2d6ro<=2)
    \\
    \\Arithmetic:
    \\  +, -, *, /          Combine dice and numbers (e.g., 2d6+5, 1d20+1d4)
    \\
;

pub const Config = struct {
    seed: ?u64 = null,
    show_seed: bool = false,
    show_rerolls: bool = false,
    no_labels: bool = false,
    result_only: bool = false,
    help: bool = false,
    version: bool = false,
    dice_specs: []const []const u8 = &.{},
};

pub const ArgParseError = error{
    UnknownOption,
    MissingSeedValue,
    InvalidSeedValue,
    OutOfMemory,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) ArgParseError!Config {
    var config = Config{};
    var dice_list: std.ArrayList([]const u8) = .empty;
    defer dice_list.deinit(allocator);

    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.help = true;
            return config;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            config.version = true;
            return config;
        } else if (std.mem.eql(u8, arg, "--show-seed")) {
            config.show_seed = true;
        } else if (std.mem.eql(u8, arg, "--show-rerolls")) {
            config.show_rerolls = true;
        } else if (std.mem.eql(u8, arg, "--no-labels")) {
            config.no_labels = true;
        } else if (std.mem.eql(u8, arg, "--result-only")) {
            config.result_only = true;
        } else if (std.mem.eql(u8, arg, "--seed") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) {
                return error.MissingSeedValue;
            }
            config.seed = std.fmt.parseInt(u64, args[i], 10) catch {
                return error.InvalidSeedValue;
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            // Positional argument - dice spec
            dice_list.append(allocator, arg) catch return error.OutOfMemory;
        }
    }

    config.dice_specs = dice_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return config;
}

const testing = std.testing;

/// parseArgs skips argv[0], so tests supply a dummy program name.
fn parse(args: []const [:0]const u8) ArgParseError!Config {
    return parseArgs(testing.allocator, args);
}

test "parseArgs collects positional dice specs" {
    const config = try parse(&.{ "toss", "2d6", "4d6k3" });
    defer testing.allocator.free(config.dice_specs);
    try testing.expectEqual(@as(usize, 2), config.dice_specs.len);
    try testing.expectEqualStrings("2d6", config.dice_specs[0]);
    try testing.expectEqualStrings("4d6k3", config.dice_specs[1]);
}

test "parseArgs defaults every flag to off" {
    const config = try parse(&.{ "toss", "1d6" });
    defer testing.allocator.free(config.dice_specs);
    try testing.expect(config.seed == null);
    try testing.expect(!config.show_seed);
    try testing.expect(!config.show_rerolls);
    try testing.expect(!config.no_labels);
    try testing.expect(!config.result_only);
    try testing.expect(!config.help);
    try testing.expect(!config.version);
}

test "parseArgs recognises each long flag" {
    const config = try parse(&.{ "toss", "--show-seed", "--show-rerolls", "--no-labels", "--result-only", "1d6" });
    defer testing.allocator.free(config.dice_specs);
    try testing.expect(config.show_seed);
    try testing.expect(config.show_rerolls);
    try testing.expect(config.no_labels);
    try testing.expect(config.result_only);
    try testing.expectEqual(@as(usize, 1), config.dice_specs.len);
}

test "parseArgs accepts --seed and -s" {
    const long = try parse(&.{ "toss", "--seed", "1234", "1d6" });
    defer testing.allocator.free(long.dice_specs);
    try testing.expectEqual(@as(?u64, 1234), long.seed);

    const short = try parse(&.{ "toss", "-s", "7", "1d6" });
    defer testing.allocator.free(short.dice_specs);
    try testing.expectEqual(@as(?u64, 7), short.seed);
}

test "parseArgs stops at --help and --version" {
    const help = try parse(&.{ "toss", "--help", "2d6" });
    try testing.expect(help.help);
    const short_help = try parse(&.{ "toss", "-h" });
    try testing.expect(short_help.help);
    const ver = try parse(&.{ "toss", "--version" });
    try testing.expect(ver.version);
    const short_ver = try parse(&.{ "toss", "-V" });
    try testing.expect(short_ver.version);
}

test "parseArgs rejects a missing or malformed seed" {
    try testing.expectError(error.MissingSeedValue, parse(&.{ "toss", "--seed" }));
    try testing.expectError(error.InvalidSeedValue, parse(&.{ "toss", "--seed", "abc", "1d6" }));
    try testing.expectError(error.InvalidSeedValue, parse(&.{ "toss", "--seed", "-1", "1d6" }));
}

test "parseArgs rejects unknown options" {
    try testing.expectError(error.UnknownOption, parse(&.{ "toss", "--bogus" }));
    try testing.expectError(error.UnknownOption, parse(&.{ "toss", "-x", "1d6" }));
}

test "parseArgs accepts no dice specs" {
    const config = try parse(&.{"toss"});
    defer testing.allocator.free(config.dice_specs);
    try testing.expectEqual(@as(usize, 0), config.dice_specs.len);
}
