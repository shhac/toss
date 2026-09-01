//! Turning evaluated rolls into the coloured, column-aligned lines `toss` prints.

const std = @import("std");
const parser = @import("parser.zig");
const eval = @import("eval.zig");
const cli = @import("cli.zig");

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

fn renderDie(
    out: *std.Io.Writer,
    term: std.Io.Terminal,
    config: cli.Config,
    die: eval.DieResult,
    is_fudge: bool,
    color: std.Io.Terminal.Color,
    layout: Layout,
) !void {
    if (!die.kept) {
        term.setColor(.dim) catch {};
        if (is_fudge) {
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
    if (config.show_rerolls and die._reroll_count > 0) {
        for (die.rerollHistory()) |hist_val| {
            try out.print("{d},", .{hist_val});
        }
    }
    // Labels are what the columns align to, so drop the padding without them.
    const width: usize = if (config.no_labels) 0 else layout.sides_width;
    if (is_fudge) {
        try out.print("{s:[1]}", .{ fudgeDisplay(die.value), width });
    } else {
        try out.print("{d:[1]}", .{ die.value, width });
    }
    if (die.exploded) try out.print("*", .{});
}

/// Render the `[label] d1 d2 ... = total` line for one evaluated expression.
pub fn renderRow(
    out: *std.Io.Writer,
    term: std.Io.Terminal,
    config: cli.Config,
    group: ColorGroup,
    expr: parser.Expr,
    result: *const eval.RollResult,
    layout: Layout,
) !void {
    if (config.result_only) {
        term.setColor(.bold) catch {};
        try out.print("{d}", .{result.total});
        term.setColor(.reset) catch {};
        try out.print("\n", .{});
        return;
    }

    if (!config.no_labels) {
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
            if (die_index > 0 or !config.no_labels) try out.print(" ", .{});
            const color = group.results[die_index % group.results.len];
            try renderDie(out, term, config, die, dice_result.sides == 0, color, layout);
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
