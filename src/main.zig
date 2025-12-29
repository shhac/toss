const std = @import("std");
const parser = @import("parser.zig");
const eval = @import("eval.zig");
const rng_mod = @import("rng.zig");

const version = "0.5.1";

const help_text =
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

const Config = struct {
    seed: ?u64 = null,
    show_seed: bool = false,
    show_rerolls: bool = false,
    no_labels: bool = false,
    result_only: bool = false,
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

/// Calculate digit count for signed integers
fn signedDigitCount(n: i32) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var value = if (n < 0) -n else n;
    while (value > 0) : (value = @divTrunc(value, 10)) {
        count += 1;
    }
    if (n < 0) count += 1; // Account for minus sign
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

/// Format a Fudge die value (stored as 1, 2, 3) for display as -1, 0, +1
fn formatFudgeValue(writer: anytype, value: u32, width: usize) !void {
    // Fudge dice: 1 -> "-1", 2 -> " 0", 3 -> "+1"
    const display_str: []const u8 = switch (value) {
        1 => "-1",
        2 => " 0",
        3 => "+1",
        else => "??", // Should never happen
    };
    // Pad to width (Fudge display is always 2 chars)
    const display_width: usize = 2;
    for (0..(width -| display_width)) |_| {
        try writer.writeByte(' ');
    }
    try writer.print("{s}", .{display_str});
}

/// Format an expression for display (reconstructs the original notation)
fn formatExpr(writer: anytype, expr: parser.Expr) !void {
    try formatExprValue(writer, expr.base);
    for (expr.operations) |op| {
        const op_char: u8 = switch (op.op) {
            .add => '+',
            .sub => '-',
            .mul => '*',
            .div => '/',
        };
        try writer.writeByte(op_char);
        try formatExprValue(writer, op.value);
    }
}

fn formatExprValue(writer: anytype, value: parser.ExprValue) !void {
    switch (value) {
        .dice => |dice| {
            try writer.print("{d}d", .{dice.count});
            if (dice.sides == 0) {
                try writer.writeByte('F');
            } else if (dice.sides == 100) {
                try writer.print("100", .{});
            } else {
                try writer.print("{d}", .{dice.sides});
            }
            // Format explode modifier (!, !!, !p)
            if (dice.explode) |ex| {
                switch (ex.explode_type) {
                    .standard => try writer.writeByte('!'),
                    .compound => try writer.print("!!", .{}),
                    .penetrating => try writer.print("!p", .{}),
                }
                // Format compare point if present
                if (ex.compare) |cmp| {
                    switch (cmp.op) {
                        .eq => try writer.print("={d}", .{cmp.value}),
                        .gt => try writer.print(">{d}", .{cmp.value}),
                        .lt => try writer.print("<{d}", .{cmp.value}),
                        .gte => try writer.print(">={d}", .{cmp.value}),
                        .lte => try writer.print("<={d}", .{cmp.value}),
                    }
                }
            }
            // Format reroll modifier (r, ro)
            if (dice.reroll) |rr| {
                if (rr.once) {
                    try writer.print("ro", .{});
                } else {
                    try writer.writeByte('r');
                }
                // Format compare point if present
                if (rr.compare) |cmp| {
                    switch (cmp.op) {
                        .eq => try writer.print("{d}", .{cmp.value}),
                        .gt => try writer.print(">{d}", .{cmp.value}),
                        .lt => try writer.print("<{d}", .{cmp.value}),
                        .gte => try writer.print(">={d}", .{cmp.value}),
                        .lte => try writer.print("<={d}", .{cmp.value}),
                    }
                }
            }
            if (dice.keep_drop) |kd| {
                switch (kd) {
                    .keep_highest => |n| try writer.print("k{d}", .{n}),
                    .keep_lowest => |n| try writer.print("kl{d}", .{n}),
                    .drop_highest => |n| try writer.print("dh{d}", .{n}),
                    .drop_lowest => |n| try writer.print("d{d}", .{n}),
                }
            }
        },
        .number => |num| {
            try writer.print("{d}", .{num});
        },
    }
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

    // First pass: parse all expressions and find max values for padding
    var max_sides: u32 = 0;
    var max_label_len: usize = 0;
    var parsed_exprs: std.ArrayList(parser.Expr) = .{};
    defer parsed_exprs.deinit(allocator);
    var has_errors = false;

    // Buffer for formatting expressions to measure label length
    var label_buf: [128]u8 = undefined;

    for (config.dice_specs) |spec_str| {
        const expr = parser.parse(spec_str) catch |parse_err| {
            stderr_tty.setColor(&err.interface, .red) catch {};
            try err.interface.print("Error: ", .{});
            stderr_tty.setColor(&err.interface, .reset) catch {};
            switch (parse_err) {
                error.InvalidFormat => try err.interface.print("Invalid dice format '{s}' (expected NdN, e.g., 2d6)\n", .{spec_str}),
                error.InvalidCount => try err.interface.print("Invalid dice count in '{s}'\n", .{spec_str}),
                error.InvalidSides => try err.interface.print("Invalid sides in '{s}'\n", .{spec_str}),
                error.Overflow => try err.interface.print("Number too large in '{s}'\n", .{spec_str}),
                error.UnexpectedCharacter => try err.interface.print("Unexpected character in '{s}'\n", .{spec_str}),
                error.UnexpectedEndOfInput => try err.interface.print("Unexpected end of input in '{s}'\n", .{spec_str}),
                error.TooManyOperations => try err.interface.print("Too many operations in '{s}'\n", .{spec_str}),
                error.DivisionByZero => try err.interface.print("Division by zero in '{s}'\n", .{spec_str}),
                error.InvalidModifier => try err.interface.print("Invalid modifier in '{s}'\n", .{spec_str}),
            }
            try err.interface.flush();
            has_errors = true;
            continue;
        };

        // Find max sides across all dice in expression (before storing)
        if (expr.base == .dice) {
            if (expr.base.dice.sides > max_sides) {
                max_sides = expr.base.dice.sides;
            }
        }
        for (expr.operations) |op| {
            if (op.value == .dice) {
                if (op.value.dice.sides > max_sides) {
                    max_sides = op.value.dice.sides;
                }
            }
        }

        // Calculate label length for this expression
        var label_stream = std.io.fixedBufferStream(&label_buf);
        formatExpr(label_stream.writer(), expr) catch {};
        const label_len = label_stream.pos;
        if (label_len > max_label_len) {
            max_label_len = label_len;
        }

        try parsed_exprs.append(allocator, expr);
    }

    // Handle case where all specs failed
    if (parsed_exprs.items.len == 0) {
        if (has_errors) {
            std.process.exit(1);
        }
        return; // No dice specs provided
    }

    // Fix up operation slices after all appends (ArrayList may have reallocated)
    // The slice inside each Expr points to its internal _operations_buf, but after
    // copying the struct, we need to re-point to the copied buffer
    for (parsed_exprs.items) |*stored_expr| {
        stored_expr.operations = stored_expr._operations_buf[0..stored_expr._operations_len];
    }

    // Calculate padding width
    const sides_width = digitCount(max_sides);

    // Second pass: evaluate and output
    var row_index: usize = 0;
    for (parsed_exprs.items) |expr| {
        // Evaluate the expression
        var result = eval.evaluate(expr, &rng) catch |eval_err| {
            stderr_tty.setColor(&err.interface, .red) catch {};
            try err.interface.print("Error: ", .{});
            stderr_tty.setColor(&err.interface, .reset) catch {};
            switch (eval_err) {
                error.DivisionByZero => try err.interface.print("Division by zero\n", .{}),
                error.Overflow => try err.interface.print("Arithmetic overflow\n", .{}),
                error.TooManyDice => try err.interface.print("Too many dice to roll\n", .{}),
            }
            try err.interface.flush();
            continue;
        };

        // Fix up slices to point to copied buffers (needed because slices contain pointers
        // that become invalid after struct copy)
        result.dice_rolls = result._rolls_buf[0..result._rolls_len];
        for (result._rolls_buf[0..result._rolls_len]) |*roll| {
            roll.dice_results = roll._dice_buf[0..roll._dice_len];
        }

        // Get color group for this row (cycles every 3 rows)
        const group = color_groups[row_index % color_groups.len];

        // Handle --result-only: just print the total
        if (config.result_only) {
            stdout_tty.setColor(&out.interface, .bold) catch {};
            try out.interface.print("{d}", .{result.total});
            stdout_tty.setColor(&out.interface, .reset) catch {};
            try out.interface.print("\n", .{});
            row_index += 1;
            continue;
        }

        // Print the expression label (dim color) unless --no-labels
        if (!config.no_labels) {
            stdout_tty.setColor(&out.interface, group.label) catch {};
            try out.interface.print("[", .{});

            // Format the expression to get its length, then pad with underscores
            var expr_label_stream = std.io.fixedBufferStream(&label_buf);
            try formatExpr(expr_label_stream.writer(), expr);
            const expr_len = expr_label_stream.pos;
            const padding_needed = max_label_len - expr_len;

            // Write underscore padding
            for (0..padding_needed) |_| {
                try out.interface.print("_", .{});
            }

            // Write the expression
            try out.interface.print("{s}", .{label_buf[0..expr_len]});
            try out.interface.print("]", .{});
            stdout_tty.setColor(&out.interface, .reset) catch {};
        }

        // Print dice results
        var die_index: usize = 0;
        var first_die = true;
        for (result.dice_rolls) |dice_result| {
            for (dice_result.dice_results) |die| {
                // Add space before die (skip for very first die when no_labels)
                if (!first_die or !config.no_labels) {
                    try out.interface.print(" ", .{});
                }
                first_die = false;

                if (die.kept) {
                    // Normal die result with color
                    const result_color = group.results[die_index % group.results.len];
                    stdout_tty.setColor(&out.interface, .reset) catch {};
                    stdout_tty.setColor(&out.interface, result_color) catch {};
                    // Show reroll history if enabled and there was a reroll
                    if (config.show_rerolls and die._reroll_count > 0) {
                        for (die.rerollHistory()) |hist_val| {
                            try out.interface.print("{d},", .{hist_val});
                        }
                    }
                    if (dice_result.sides == 0) {
                        // Fudge dice: display as -1, 0, +1
                        if (config.no_labels) {
                            // No padding when labels are omitted
                            try formatFudgeValue(&out.interface, die.value, 0);
                        } else {
                            try formatFudgeValue(&out.interface, die.value, sides_width);
                        }
                    } else if (config.no_labels) {
                        // No padding when labels are omitted
                        try out.interface.print("{d}", .{die.value});
                    } else {
                        try writeRightAligned(&out.interface, die.value, sides_width, ' ');
                    }
                    // Mark exploded dice with * suffix
                    if (die.exploded) {
                        try out.interface.print("*", .{});
                    }
                } else {
                    // Dropped die - dim with strikethrough styling (~value~)
                    stdout_tty.setColor(&out.interface, .dim) catch {};
                    if (dice_result.sides == 0) {
                        // Fudge dice: display as -1, 0, +1 with strikethrough
                        const fudge_str: []const u8 = switch (die.value) {
                            1 => "-1",
                            2 => " 0",
                            3 => "+1",
                            else => "??",
                        };
                        try out.interface.print("~{s}~", .{fudge_str});
                    } else {
                        try out.interface.print("~{d}~", .{die.value});
                    }
                    // Mark dropped exploded dice too
                    if (die.exploded) {
                        try out.interface.print("*", .{});
                    }
                    stdout_tty.setColor(&out.interface, .reset) catch {};
                }

                die_index += 1;
            }
        }

        // Print total if expression has modifiers or arithmetic
        if (result.has_modifiers) {
            stdout_tty.setColor(&out.interface, .reset) catch {};
            try out.interface.print(" = ", .{});
            stdout_tty.setColor(&out.interface, .bold) catch {};
            try out.interface.print("{d}", .{result.total});
        }

        stdout_tty.setColor(&out.interface, .reset) catch {};
        try out.interface.print("\n", .{});
        row_index += 1;
    }

    try out.interface.flush();
}

pub fn main() void {
    run() catch |run_error| {
        const stderr = std.fs.File.stderr();
        var buf: [256]u8 = undefined;
        var w = stderr.writer(&buf);
        w.interface.print("Error: {s}\n", .{@errorName(run_error)}) catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    };
}
