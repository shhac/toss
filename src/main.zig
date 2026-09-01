//! Entry point: wires the CLI surface to the parser, evaluator, and renderer.

const std = @import("std");
const parser = @import("parser.zig");
const eval = @import("eval.zig");
const rng_mod = @import("rng.zig");
const cli = @import("cli.zig");
const render = @import("render.zig");

/// What the first pass learned about the expressions it parsed.
const Measured = struct {
    max_sides: u32 = 0,
    max_label_len: usize = 0,
    has_errors: bool = false,
};

/// " at position N" when the parser stopped on a specific character, so the
/// message points at the problem rather than just naming the whole input.
fn writeErrorLocation(err_out: *std.Io.Writer, diag: parser.Diagnostic) !void {
    const found = diag.found orelse return;
    if (std.ascii.isPrint(found)) {
        try err_out.print(" (at position {d}: '{c}')", .{ diag.pos + 1, found });
    } else {
        try err_out.print(" (at position {d}: byte 0x{x:0>2})", .{ diag.pos + 1, found });
    }
}

fn reportParseError(
    err_out: *std.Io.Writer,
    term: std.Io.Terminal,
    spec_str: []const u8,
    parse_err: parser.ParseError,
    diag: parser.Diagnostic,
) !void {
    term.setColor(.red) catch {};
    try err_out.print("Error: ", .{});
    term.setColor(.reset) catch {};
    switch (parse_err) {
        error.InvalidFormat => try err_out.print("Invalid dice format '{s}'", .{spec_str}),
        error.InvalidCount => try err_out.print("Invalid dice count in '{s}'", .{spec_str}),
        error.InvalidSides => try err_out.print("Invalid sides in '{s}'", .{spec_str}),
        error.Overflow => try err_out.print("Number too large in '{s}'", .{spec_str}),
        error.UnexpectedCharacter => try err_out.print("Unexpected character in '{s}'", .{spec_str}),
        error.UnexpectedEndOfInput => try err_out.print("Unexpected end of input in '{s}'", .{spec_str}),
        error.TooManyOperations => try err_out.print("Too many operations in '{s}'", .{spec_str}),
        error.InvalidModifier => try err_out.print("Invalid modifier in '{s}'", .{spec_str}),
    }
    try writeErrorLocation(err_out, diag);
    // The shape hint reads better after the location than before it.
    if (parse_err == error.InvalidFormat) {
        try err_out.print("; expected NdN, e.g., 2d6", .{});
    }
    try err_out.print("\n", .{});
    try err_out.flush();
}

fn reportArgError(
    err_out: *std.Io.Writer,
    arg_err: cli.ArgParseError,
) !void {
    switch (arg_err) {
        error.UnknownOption => {
            try err_out.print("Error: Unknown option\n", .{});
            try err_out.print("Run 'toss --help' for usage information.\n", .{});
        },
        error.MissingSeedValue => try err_out.print("Error: --seed requires a value\n", .{}),
        error.InvalidSeedValue => try err_out.print("Error: --seed value must be a positive integer\n", .{}),
        error.OutOfMemory => try err_out.print("Error: Out of memory\n", .{}),
    }
    try err_out.flush();
}

fn reportEvalError(
    err_out: *std.Io.Writer,
    term: std.Io.Terminal,
    eval_err: eval.EvalError,
) !void {
    term.setColor(.red) catch {};
    try err_out.print("Error: ", .{});
    term.setColor(.reset) catch {};
    switch (eval_err) {
        error.DivisionByZero => try err_out.print("Division by zero\n", .{}),
        error.Overflow => try err_out.print("Arithmetic overflow\n", .{}),
        error.TooManyDice => try err_out.print("Too many dice to roll\n", .{}),
    }
    try err_out.flush();
}

/// Widest number of sides across every dice term in the expression.
fn parseAndMeasure(
    allocator: std.mem.Allocator,
    dice_specs: []const []const u8,
    exprs: *std.ArrayList(parser.Expr),
    err_out: *std.Io.Writer,
    term: std.Io.Terminal,
) !Measured {
    var measured: Measured = .{};
    for (dice_specs) |spec_str| {
        var diag: parser.Diagnostic = .{};
        const expr = parser.parseTraced(spec_str, &diag) catch |parse_err| {
            try reportParseError(err_out, term, spec_str, parse_err, diag);
            measured.has_errors = true;
            continue;
        };
        measured.max_sides = @max(measured.max_sides, render.maxSides(expr));
        measured.max_label_len = @max(measured.max_label_len, render.labelWidth(expr));
        try exprs.append(allocator, expr);
    }
    return measured;
}

/// Parse arguments, roll each expression, and render the results.
fn run(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Get command line arguments
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Set up buffered writers
    var out_buf: [4096]u8 = undefined;
    var out_file: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_file.interface;

    var err_buf: [256]u8 = undefined;
    var err_file: std.Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const err_out = &err_file.interface;

    // Detect TTY for colored output (stdout for results, stderr for errors/seed)
    const no_color = try init.minimal.environ.containsUnempty(allocator, "NO_COLOR");
    const clicolor_force = try init.minimal.environ.containsUnempty(allocator, "CLICOLOR_FORCE");
    const stdout_term: std.Io.Terminal = .{
        .writer = out,
        .mode = try .detect(io, .stdout(), no_color, clicolor_force),
    };
    const stderr_term: std.Io.Terminal = .{
        .writer = err_out,
        .mode = try .detect(io, .stderr(), no_color, clicolor_force),
    };

    // Parse arguments
    const config = cli.parseArgs(allocator, args) catch |arg_err| {
        try reportArgError(err_out, arg_err);
        std.process.exit(1);
    };
    defer allocator.free(config.dice_specs);

    // Handle --help
    if (config.help) {
        try out.print("{s}", .{cli.help_text});
        try out.flush();
        return;
    }

    // Handle --cli.version
    if (config.version) {
        try out.print("toss {s}\n", .{cli.version});
        try out.flush();
        return;
    }

    // Initialize RNG
    var rng = rng_mod.Rng.init(io, config.seed);

    // Show seed if requested (all dim)
    if (config.show_seed) {
        stderr_term.setColor(.dim) catch {};
        try err_out.print("[seed] {d}\n", .{rng.seed});
        stderr_term.setColor(.reset) catch {};
        try err_out.flush();
    }

    var parsed_exprs: std.ArrayList(parser.Expr) = .empty;
    defer parsed_exprs.deinit(allocator);

    const measured = try parseAndMeasure(allocator, config.dice_specs, &parsed_exprs, err_out, stderr_term);

    if (parsed_exprs.items.len == 0) {
        if (measured.has_errors) std.process.exit(1);
        return; // No dice specs provided
    }

    const layout: render.Layout = .{
        .sides_width = render.digitCount(measured.max_sides),
        .max_label_len = measured.max_label_len,
    };

    const display: render.DisplayOptions = .{
        .show_rerolls = config.show_rerolls,
        .no_labels = config.no_labels,
        .result_only = config.result_only,
    };

    var failed = measured.has_errors;
    var row_index: usize = 0;
    for (parsed_exprs.items) |expr| {
        const result = eval.evaluate(expr, &rng) catch |eval_err| {
            try reportEvalError(err_out, stderr_term, eval_err);
            failed = true;
            continue;
        };
        const group = render.color_groups[row_index % render.color_groups.len];
        try render.renderRow(out, stdout_term, display, group, expr, &result, layout);
        row_index += 1;
    }

    try out.flush();

    // Any spec that failed to parse or evaluate makes the whole run a failure,
    // so callers can branch on the exit status.
    if (failed) std.process.exit(1);
}

pub fn main(init: std.process.Init) void {
    run(init) catch |run_error| {
        var buf: [256]u8 = undefined;
        var w: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &buf);
        w.interface.print("Error: {s}\n", .{@errorName(run_error)}) catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    };
}
