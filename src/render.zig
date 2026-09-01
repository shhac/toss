//! Turning evaluated rolls into the coloured, column-aligned lines `toss` prints.

const std = @import("std");
const parser = @import("parser.zig");
const eval = @import("eval.zig");

/// The subset of the CLI flags that affects rendering.
pub const DisplayOptions = struct {
    show_rerolls: bool = false,
    no_labels: bool = false,
    result_only: bool = false,
};

/// Upper bound on a rendered expression label such as "[4d6k3]".
pub const MAX_LABEL_LEN = 128;

pub const ColorGroup = struct {
    label: std.Io.Terminal.Color, // Dimmer color for the [XdY] label
    results: [3]std.Io.Terminal.Color, // Three colors that alternate for die results
};

pub const color_groups = [_]ColorGroup{
    // Group 0: Red family
    .{ .label = .dim, .results = .{ .red, .magenta, .bright_red } },
    // Group 1: Green family (yellow for contrast instead of cyan)
    .{ .label = .dim, .results = .{ .green, .yellow, .bright_green } },
    // Group 2: Blue family
    .{ .label = .dim, .results = .{ .blue, .cyan, .bright_blue } },
};

/// Calculate the number of digits needed to represent a number
pub fn digitCount(n: u32) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var value = n;
    while (value > 0) : (value /= 10) {
        count += 1;
    }
    return count;
}

/// Fudge dice are stored as 1, 2, 3 and displayed as -1, 0, +1
fn fudgeDisplay(value: u32) []const u8 {
    return switch (value) {
        1 => "-1",
        2 => " 0",
        3 => "+1",
        else => "??", // Should never happen
    };
}

/// Explode points spell out `=N`; reroll points write a bare `N`.
const EqStyle = enum { explicit_eq, bare_eq };

fn formatComparePoint(writer: *std.Io.Writer, cmp: parser.ComparePoint, eq_style: EqStyle) !void {
    const prefix: []const u8 = switch (cmp.op) {
        .eq => if (eq_style == .explicit_eq) "=" else "",
        .gt => ">",
        .lt => "<",
        .gte => ">=",
        .lte => "<=",
    };
    try writer.print("{s}{d}", .{ prefix, cmp.value });
}

/// Format an expression for display (reconstructs the original notation)
pub fn formatExpr(writer: *std.Io.Writer, expr: parser.Expr) !void {
    try formatExprValue(writer, expr.base);
    for (expr.operations()) |op| {
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

fn formatExprValue(writer: *std.Io.Writer, value: parser.ExprValue) !void {
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
                if (ex.compare) |cmp| try formatComparePoint(writer, cmp, .explicit_eq);
            }
            // Format reroll modifier (r, ro)
            if (dice.reroll) |rr| {
                if (rr.once) {
                    try writer.print("ro", .{});
                } else {
                    try writer.writeByte('r');
                }
                if (rr.compare) |cmp| try formatComparePoint(writer, cmp, .bare_eq);
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

/// Column widths shared by every rendered row.
pub const Layout = struct {
    sides_width: usize,
    max_label_len: usize,
};

/// Widest number of sides across every dice term in the expression.
pub fn maxSides(expr: parser.Expr) u32 {
    var max: u32 = 0;
    if (expr.base == .dice) max = expr.base.dice.sides;
    for (expr.operations()) |op| {
        if (op.value == .dice and op.value.dice.sides > max) max = op.value.dice.sides;
    }
    return max;
}

/// Rendered width of an expression's label, used to size the underscore padding.
pub fn labelWidth(expr: parser.Expr) usize {
    var buf: [MAX_LABEL_LEN]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    formatExpr(&stream, expr) catch {};
    return stream.end;
}

/// SGR 9 / 29. `std.Io.Terminal` has no strikethrough colour, and these are
/// only emitted where escape codes are already in use.
const strike_on = "\x1b[9m";
const strike_off = "\x1b[29m";

fn usesEscapeCodes(term: std.Io.Terminal) bool {
    return switch (term.mode) {
        .escape_codes => true,
        else => false,
    };
}

/// Write a die's value, right-aligned to `width` (0 for no padding).
fn writeDieValue(out: *std.Io.Writer, value: u32, is_fudge: bool, width: usize) !void {
    if (is_fudge) {
        try out.print("{s:[1]}", .{ fudgeDisplay(value), width });
    } else {
        try out.print("{d:[1]}", .{ value, width });
    }
}

fn renderDie(
    out: *std.Io.Writer,
    term: std.Io.Terminal,
    opts: DisplayOptions,
    die: eval.DieResult,
    is_fudge: bool,
    color: std.Io.Terminal.Color,
    layout: Layout,
) !void {
    // Labels are what the columns align to, so drop the padding without them.
    const width: usize = if (opts.no_labels) 0 else layout.sides_width;

    if (!die.kept) {
        term.setColor(.dim) catch {};
        // A terminal can strike the value through directly. Anywhere else --
        // piped output, NO_COLOR -- keeps the ~N~ marker, which is what any
        // consumer parsing this output already looks for.
        if (usesEscapeCodes(term)) {
            try out.writeAll(strike_on);
            try writeDieValue(out, die.value, is_fudge, width);
            try out.writeAll(strike_off);
        } else if (is_fudge) {
            try out.print("~{s}~", .{fudgeDisplay(die.value)});
        } else {
            try out.print("~{d}~", .{die.value});
        }
        if (die.exploded) try out.print("*", .{});
        term.setColor(.reset) catch {};
        return;
    }

    term.setColor(.reset) catch {};
    term.setColor(color) catch {};
    if (opts.show_rerolls and die._reroll_count > 0) {
        for (die.rerollHistory()) |hist_val| {
            try out.print("{d},", .{hist_val});
        }
    }
    try writeDieValue(out, die.value, is_fudge, width);
    if (die.exploded) try out.print("*", .{});
}

/// Render the `[label] d1 d2 ... = total` line for one evaluated expression.
pub fn renderRow(
    out: *std.Io.Writer,
    term: std.Io.Terminal,
    opts: DisplayOptions,
    group: ColorGroup,
    expr: parser.Expr,
    result: *const eval.RollResult,
    layout: Layout,
) !void {
    if (opts.result_only) {
        term.setColor(.bold) catch {};
        try out.print("{d}", .{result.total});
        term.setColor(.reset) catch {};
        try out.print("\n", .{});
        return;
    }

    if (!opts.no_labels) {
        var label_buf: [MAX_LABEL_LEN]u8 = undefined;
        var label_stream: std.Io.Writer = .fixed(&label_buf);
        try formatExpr(&label_stream, expr);
        const label = label_stream.buffered();

        term.setColor(group.label) catch {};
        try out.print("[", .{});
        try out.splatByteAll('_', layout.max_label_len - label.len);
        try out.print("{s}]", .{label});
        term.setColor(.reset) catch {};
    }

    var die_index: usize = 0;
    for (result.diceRolls()) |dice_result| {
        for (dice_result.diceResults()) |die| {
            // Without labels the first die opens the line, so it needs no separator.
            if (die_index > 0 or !opts.no_labels) try out.print(" ", .{});
            const color = group.results[die_index % group.results.len];
            try renderDie(out, term, opts, die, dice_result.sides == 0, color, layout);
            die_index += 1;
        }
    }

    if (result.has_modifiers) {
        term.setColor(.reset) catch {};
        try out.print(" = ", .{});
        term.setColor(.bold) catch {};
        try out.print("{d}", .{result.total});
    }

    term.setColor(.reset) catch {};
    try out.print("\n", .{});
}

const testing = std.testing;

fn expectFormatted(expected: []const u8, notation: []const u8) !void {
    var buf: [MAX_LABEL_LEN]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    const expr = try parser.parse(notation);
    try formatExpr(&stream, expr);
    try testing.expectEqualStrings(expected, stream.buffered());
}

test "formatExpr round-trips dice notation" {
    try expectFormatted("2d6", "2d6");
    try expectFormatted("2d100", "2d100");
    try expectFormatted("5", "5");
}

test "formatExpr normalises shorthand to explicit form" {
    try expectFormatted("1d6", "d6");
    try expectFormatted("1d100", "d%");
    try expectFormatted("1dF", "dF");
}

test "formatExpr round-trips keep/drop modifiers" {
    try expectFormatted("4d6k3", "4d6k3");
    try expectFormatted("4d6kl2", "4d6kl2");
    try expectFormatted("4d6dh1", "4d6dh1");
    try expectFormatted("4d6d1", "4d6d1");
}

test "formatExpr round-trips explode and reroll modifiers" {
    try expectFormatted("1d6!", "1d6!");
    try expectFormatted("2d6!!", "2d6!!");
    try expectFormatted("1d6!p", "1d6!p");
    try expectFormatted("1d6!>4", "1d6!>4");
    try expectFormatted("2d6r1", "2d6r1");
    try expectFormatted("2d6ro", "2d6ro");
    try expectFormatted("2d6r<=2", "2d6r<=2");
}

test "formatExpr round-trips arithmetic" {
    try expectFormatted("2d6+5", "2d6+5");
    try expectFormatted("1d20+1d4", "1d20+1d4");
    try expectFormatted("3d6-2", "3d6-2");
    try expectFormatted("2d6*2", "2d6*2");
    try expectFormatted("4d6/2", "4d6/2");
}

test "digitCount covers zero and power-of-ten boundaries" {
    try testing.expectEqual(@as(usize, 1), digitCount(0));
    try testing.expectEqual(@as(usize, 1), digitCount(9));
    try testing.expectEqual(@as(usize, 2), digitCount(10));
    try testing.expectEqual(@as(usize, 2), digitCount(99));
    try testing.expectEqual(@as(usize, 3), digitCount(100));
    try testing.expectEqual(@as(usize, 10), digitCount(std.math.maxInt(u32)));
}

test "fudgeDisplay maps stored values to their two-character display" {
    try testing.expectEqualStrings("-1", fudgeDisplay(1));
    try testing.expectEqualStrings(" 0", fudgeDisplay(2));
    try testing.expectEqualStrings("+1", fudgeDisplay(3));
    // Unreachable from the parser's domain, but must stay width-2.
    try testing.expectEqual(@as(usize, 2), fudgeDisplay(99).len);
}

test "maxSides finds the widest die across arithmetic terms" {
    try testing.expectEqual(@as(u32, 6), maxSides(try parser.parse("2d6")));
    try testing.expectEqual(@as(u32, 100), maxSides(try parser.parse("1d20+2d100")));
    try testing.expectEqual(@as(u32, 20), maxSides(try parser.parse("1d20+5")));
    // A bare number contributes no dice.
    try testing.expectEqual(@as(u32, 0), maxSides(try parser.parse("5")));
}

test "labelWidth matches the rendered label length" {
    try testing.expectEqual(@as(usize, 3), labelWidth(try parser.parse("2d6")));
    try testing.expectEqual(@as(usize, 5), labelWidth(try parser.parse("4d6k3")));
    try testing.expectEqual(@as(usize, 5), labelWidth(try parser.parse("1d100")));
}

// =============================================================================
// Rendered output
// =============================================================================

const TestDie = struct {
    value: u32,
    kept: bool = true,
    exploded: bool = false,
    rerolls: []const u32 = &.{},
};

/// Build a single-roll result without going through the RNG, so rendering can
/// be asserted against exact strings.
fn rollResultWith(sides: u32, dice: []const TestDie, has_modifiers: bool) eval.RollResult {
    var roll = eval.DiceRollResult{ .subtotal = 0, .sides = sides };
    for (dice) |d| {
        var die = eval.DieResult{ .value = d.value, .kept = d.kept, .exploded = d.exploded };
        for (d.rerolls) |r| {
            die._reroll_history[die._reroll_count] = r;
            die._reroll_count += 1;
        }
        roll._dice_buf[roll._dice_len] = die;
        roll._dice_len += 1;
    }
    roll.subtotal = roll.keptTotal();

    var result = eval.RollResult{ .total = roll.subtotal, .has_modifiers = has_modifiers };
    result._rolls_buf[0] = roll;
    result._rolls_len = 1;
    return result;
}

fn expectRendered(
    expected: []const u8,
    notation: []const u8,
    sides: u32,
    dice: []const TestDie,
    has_modifiers: bool,
    opts: DisplayOptions,
    layout: Layout,
) !void {
    var buf: [512]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    const term: std.Io.Terminal = .{ .writer = &stream, .mode = .no_color };

    const expr = try parser.parse(notation);
    const result = rollResultWith(sides, dice, has_modifiers);
    try renderRow(&stream, term, opts, color_groups[0], expr, &result, layout);
    try testing.expectEqualStrings(expected, stream.buffered());
}

const wide: Layout = .{ .sides_width = 1, .max_label_len = 5 };

test "renderRow pads the label with underscores to the widest label" {
    try expectRendered("[__2d6] 3 4\n", "2d6", 6, &.{ .{ .value = 3 }, .{ .value = 4 } }, false, .{}, wide);
}

test "renderRow marks dropped dice with tildes" {
    try expectRendered(
        "[_4d6k3] 6 5 4 ~1~ = 15\n",
        "4d6k3",
        6,
        &.{ .{ .value = 6 }, .{ .value = 5 }, .{ .value = 4 }, .{ .value = 1, .kept = false } },
        true,
        .{},
        .{ .sides_width = 1, .max_label_len = 6 },
    );
}

test "renderRow marks exploded dice with an asterisk" {
    try expectRendered(
        "[_1d6!] 6* 3 = 9\n",
        "1d6!",
        6,
        &.{ .{ .value = 6, .exploded = true }, .{ .value = 3 } },
        true,
        .{},
        .{ .sides_width = 1, .max_label_len = 5 },
    );
}

test "renderRow shows reroll history only when asked" {
    const dice = &[_]TestDie{.{ .value = 5, .rerolls = &.{ 1, 2 } }};
    try expectRendered("[_2d6r1] 1,2,5 = 5\n", "2d6r1", 6, dice, true, .{ .show_rerolls = true }, .{ .sides_width = 1, .max_label_len = 6 });
    try expectRendered("[_2d6r1] 5 = 5\n", "2d6r1", 6, dice, true, .{}, .{ .sides_width = 1, .max_label_len = 6 });
}

test "renderRow right-aligns dice to the widest die" {
    try expectRendered(
        "[1d100]   7  61\n",
        "1d100",
        100,
        &.{ .{ .value = 7 }, .{ .value = 61 } },
        false,
        .{},
        .{ .sides_width = 3, .max_label_len = 5 },
    );
}

test "renderRow renders fudge dice as -1, 0, +1" {
    try expectRendered(
        "[__3dF] -1  0 +1\n",
        "3dF",
        0,
        &.{ .{ .value = 1 }, .{ .value = 2 }, .{ .value = 3 } },
        false,
        .{},
        .{ .sides_width = 2, .max_label_len = 5 },
    );
}

test "renderRow with no_labels omits the label and the padding" {
    try expectRendered("3 4\n", "2d6", 6, &.{ .{ .value = 3 }, .{ .value = 4 } }, false, .{ .no_labels = true }, wide);
}

test "renderRow with result_only prints just the total" {
    try expectRendered("7\n", "2d6", 6, &.{ .{ .value = 3 }, .{ .value = 4 } }, true, .{ .result_only = true }, wide);
}

fn renderToBuf(buf: []u8, mode: std.Io.Terminal.Mode, notation: []const u8, sides: u32, dice: []const TestDie) ![]const u8 {
    var stream: std.Io.Writer = .fixed(buf);
    const term: std.Io.Terminal = .{ .writer = &stream, .mode = mode };
    const expr = try parser.parse(notation);
    const result = rollResultWith(sides, dice, true);
    try renderRow(&stream, term, .{}, color_groups[0], expr, &result, .{ .sides_width = 1, .max_label_len = 5 });
    return stream.buffered();
}

test "a terminal strikes dropped dice through instead of using tildes" {
    var buf: [512]u8 = undefined;
    const out = try renderToBuf(&buf, .escape_codes, "2d6", 6, &.{
        .{ .value = 5 },
        .{ .value = 1, .kept = false },
    });

    try testing.expect(std.mem.indexOf(u8, out, strike_on) != null);
    try testing.expect(std.mem.indexOf(u8, out, strike_off) != null);
    // The tilde marker is the fallback for output that cannot be styled.
    try testing.expect(std.mem.indexOfScalar(u8, out, '~') == null);
}

test "output without escape codes keeps the tilde marker" {
    var buf: [512]u8 = undefined;
    const out = try renderToBuf(&buf, .no_color, "2d6", 6, &.{
        .{ .value = 5 },
        .{ .value = 1, .kept = false },
    });

    try testing.expectEqualStrings("[__2d6] 5 ~1~ = 5\n", out);
    try testing.expect(std.mem.indexOf(u8, out, strike_on) == null);
}

test "struck fudge dice keep their sign column" {
    var buf: [512]u8 = undefined;
    const out = try renderToBuf(&buf, .escape_codes, "2dF", 0, &.{
        .{ .value = 3 },
        .{ .value = 2, .kept = false },
    });

    // The dropped die renders as the plain fudge display, struck through --
    // no tildes wrapping a padded value.
    try testing.expect(std.mem.indexOf(u8, out, strike_on ++ " 0" ++ strike_off) != null);
}
