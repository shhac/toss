const std = @import("std");
const dice = @import("dice.zig");
const rng_mod = @import("rng.zig");

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
    \\
;

const Config = struct {
    seed: ?u64 = null,
    show_seed: bool = false,
    help: bool = false,
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

    // Detect TTY for colored output
    const tty_config = std.io.tty.Config.detect(stderr);

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

    // Initialize RNG
    var rng = rng_mod.Rng.init(config.seed);

    // Show seed if requested
    if (config.show_seed) {
        tty_config.setColor(&err.interface, .dim) catch {};
        try err.interface.print("[seed] ", .{});
        tty_config.setColor(&err.interface, .reset) catch {};
        try err.interface.print("{d}\n", .{rng.seed});
        try err.interface.flush();
    }

    // Process each dice spec
    for (config.dice_specs) |spec_str| {
        const spec = dice.parse(spec_str) catch |parse_err| {
            tty_config.setColor(&err.interface, .red) catch {};
            try err.interface.print("Error: ", .{});
            tty_config.setColor(&err.interface, .reset) catch {};
            switch (parse_err) {
                error.InvalidFormat => try err.interface.print("Invalid dice format '{s}' (expected NdN, e.g., 2d6)\n", .{spec_str}),
                error.InvalidCount => try err.interface.print("Invalid dice count in '{s}'\n", .{spec_str}),
                error.InvalidSides => try err.interface.print("Invalid sides in '{s}'\n", .{spec_str}),
                error.Overflow => try err.interface.print("Number too large in '{s}'\n", .{spec_str}),
            }
            try err.interface.flush();
            continue;
        };

        // Print the dice spec label
        try out.interface.print("[{s}]", .{spec_str});

        // Roll and print each die
        for (0..spec.count) |_| {
            const result = rng.roll(spec.sides);
            try out.interface.print(" {d}", .{result});
        }

        try out.interface.print("\n", .{});
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
