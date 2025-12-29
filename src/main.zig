const std = @import("std");
const dice = @import("dice.zig");
const rng_mod = @import("rng.zig");

const version = "0.2.0";

const help_text =
    \\toss - A dice rolling CLI
    \\
    \\Usage: toss [OPTIONS] <DICE>...
    \\
    \\Arguments:
    \\  <DICE>...           Dice specifications (e.g., 2d6, 1d4)
    \\
    \\Options:
    \\  -s, --seed <NUM>    Seed for reproducible rolls
    \\      --show-seed     Output the seed used to stderr
    \\  -h, --help          Display this help message
    \\  -V, --version       Show version information
    \\
;

const Config = struct {
    seed: ?u64 = null,
    show_seed: bool = false,
    help: bool = false,
    version: bool = false,
    dice_specs: []const []const u8 = &.{},
};

const ArgParseError = error{
    UnknownOption,
    MissingSeedValue,
    InvalidSeedValue,
    OutOfMemory,
};

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) ArgParseError!Config {
    var config = Config{};
    var dice_list: std.ArrayList([]const u8) = .{};

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

// Color groups for die roll output (cycles every 3 rows)
const ColorGroup = struct {
    label: std.io.tty.Color, // Dimmer color for the [XdY] label
    results: [3]std.io.tty.Color, // Three colors that alternate for die results
};

const color_groups = [_]ColorGroup{
    // Group 0: Red family
    .{ .label = .dim, .results = .{ .red, .magenta, .bright_red } },
    // Group 1: Green family (yellow for contrast instead of cyan)
    .{ .label = .dim, .results = .{ .green, .yellow, .bright_green } },
    // Group 2: Blue family
    .{ .label = .dim, .results = .{ .blue, .cyan, .bright_blue } },
};

/// Calculate the number of digits needed to represent a number
fn digitCount(n: u32) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var value = n;
    while (value > 0) : (value /= 10) {
        count += 1;
    }
    return count;
}

/// Write a right-aligned number with the given width and padding character
fn writeRightAligned(writer: anytype, value: u32, width: usize, pad_char: u8) !void {
    const value_width = digitCount(value);
    // Add leading padding for alignment
    for (0..(width -| value_width)) |_| {
        try writer.writeByte(pad_char);
    }
    try writer.print("{d}", .{value});
}

fn run() !void {
    // Set up allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Get file handles
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // Set up buffered writers
    var out_buf: [4096]u8 = undefined;
    var out = stdout.writer(&out_buf);

    var err_buf: [256]u8 = undefined;
    var err = stderr.writer(&err_buf);

    // Detect TTY for colored output (stdout for results, stderr for errors/seed)
    const stdout_tty = std.io.tty.Config.detect(stdout);
    const stderr_tty = std.io.tty.Config.detect(stderr);

    // Parse arguments
    const config = parseArgs(allocator, args) catch |parse_err| {
        switch (parse_err) {
            error.UnknownOption => {
                try err.interface.print("Error: Unknown option\n", .{});
                try err.interface.print("Run 'toss --help' for usage information.\n", .{});
            },
            error.MissingSeedValue => {
                try err.interface.print("Error: --seed requires a value\n", .{});
            },
            error.InvalidSeedValue => {
                try err.interface.print("Error: --seed value must be a positive integer\n", .{});
            },
            error.OutOfMemory => {
                try err.interface.print("Error: Out of memory\n", .{});
            },
        }
        try err.interface.flush();
        std.process.exit(1);
    };
    defer allocator.free(config.dice_specs);

    // Handle --help
    if (config.help) {
        try out.interface.print("{s}", .{help_text});
        try out.interface.flush();
        return;
    }

    // Handle --version
    if (config.version) {
        try out.interface.print("toss {s}\n", .{version});
        try out.interface.flush();
        return;
    }

    // Initialize RNG
    var rng = rng_mod.Rng.init(config.seed);

    // Show seed if requested (all dim)
    if (config.show_seed) {
        stderr_tty.setColor(&err.interface, .dim) catch {};
        try err.interface.print("[seed] {d}\n", .{rng.seed});
        stderr_tty.setColor(&err.interface, .reset) catch {};
        try err.interface.flush();
    }

    // First pass: parse all dice specs and find max count/sides values
    var max_count: u32 = 0;
    var max_sides: u32 = 0;
    var parsed_specs: std.ArrayList(dice.DiceSpec) = .{};
    defer parsed_specs.deinit(allocator);

    for (config.dice_specs) |spec_str| {
        const spec = dice.parse(spec_str) catch |parse_err| {
            stderr_tty.setColor(&err.interface, .red) catch {};
            try err.interface.print("Error: ", .{});
            stderr_tty.setColor(&err.interface, .reset) catch {};
            switch (parse_err) {
                error.InvalidFormat => try err.interface.print("Invalid dice format '{s}' (expected NdN, e.g., 2d6)\n", .{spec_str}),
                error.InvalidCount => try err.interface.print("Invalid dice count in '{s}'\n", .{spec_str}),
                error.InvalidSides => try err.interface.print("Invalid sides in '{s}'\n", .{spec_str}),
                error.Overflow => try err.interface.print("Number too large in '{s}'\n", .{spec_str}),
            }
            try err.interface.flush();
            // Store a sentinel value for invalid specs
            try parsed_specs.append(allocator, .{ .count = 0, .sides = 0 });
            continue;
        };

        if (spec.count > max_count) {
            max_count = spec.count;
        }
        if (spec.sides > max_sides) {
            max_sides = spec.sides;
        }
        try parsed_specs.append(allocator, spec);
    }

    // Calculate the width needed for the max count and sides values
    const count_width = digitCount(max_count);
    const sides_width = digitCount(max_sides);

    // Second pass: output with padding
    var row_index: usize = 0;
    for (config.dice_specs, 0..) |_, spec_index| {
        const spec = parsed_specs.items[spec_index];

        // Skip invalid specs (already reported error)
        if (spec.count == 0 and spec.sides == 0) {
            continue;
        }

        // Get color group for this row (cycles every 3 rows)
        const group = color_groups[row_index % color_groups.len];

        // Print the dice spec label with padding (dim color)
        // Format: [<padded_count>d<padded_sides>]
        stdout_tty.setColor(&out.interface, group.label) catch {};
        try out.interface.print("[", .{});
        try writeRightAligned(&out.interface, spec.count, count_width, '_');
        try out.interface.print("d", .{});
        try writeRightAligned(&out.interface, spec.sides, sides_width, '_');
        try out.interface.print("]", .{});
        stdout_tty.setColor(&out.interface, .reset) catch {};

        // Roll and print each die (alternating colors within group) with padding
        for (0..spec.count) |die_index| {
            const result = rng.roll(spec.sides);
            const result_color = group.results[die_index % group.results.len];
            stdout_tty.setColor(&out.interface, result_color) catch {};
            try out.interface.print(" ", .{});
            try writeRightAligned(&out.interface, result, sides_width, ' ');
        }

        stdout_tty.setColor(&out.interface, .reset) catch {};
        try out.interface.print("\n", .{});
        row_index += 1;
    }

    try out.interface.flush();
}

pub fn main() void {
    run() catch |err| {
        const stderr = std.fs.File.stderr();
        var buf: [256]u8 = undefined;
        var w = stderr.writer(&buf);
        w.interface.print("Error: {s}\n", .{@errorName(err)}) catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    };
}
