const std = @import("std");
const parser = @import("parser.zig");
const rng_mod = @import("rng.zig");

const Allocator = std.mem.Allocator;

/// Maximum number of dice that can be rolled in a single dice expression
pub const MAX_DICE = 256;

/// Result of a single die roll
pub const DieResult = struct {
    value: u32,
    kept: bool, // false if dropped by modifier
};

/// Result of evaluating a dice roll expression (e.g., 4d6k3)
pub const DiceRollResult = struct {
    dice_results: []const DieResult, // Individual die values
    subtotal: i32, // Sum of kept dice

    // Internal storage
    _dice_buf: [MAX_DICE]DieResult = undefined,
    _dice_len: usize = 0,

    /// Sum of all kept dice
    pub fn keptTotal(self: *const DiceRollResult) i32 {
        var total: i32 = 0;
        for (self.dice_results) |die| {
            if (die.kept) {
                total += @intCast(die.value);
            }
        }
        return total;
    }
};

/// Result of evaluating a complete expression
pub const RollResult = struct {
    /// All dice roll results in the expression (in order of appearance)
    dice_rolls: []const DiceRollResult,
    /// Final total after all arithmetic operations
    total: i32,
    /// Whether the expression has modifiers or arithmetic (determines if we show total)
    has_modifiers: bool,

    // Internal storage
    _rolls_buf: [parser.MAX_OPERATIONS + 1]DiceRollResult = undefined,
    _rolls_len: usize = 0,
};

/// Evaluation errors
pub const EvalError = error{
    /// Division by zero in expression
    DivisionByZero,
    /// Arithmetic overflow
    Overflow,
    /// Too many dice to roll
    TooManyDice,
};

/// Evaluate a dice roll specification, applying any modifiers
fn evaluateDiceRoll(dice: parser.DiceRoll, rng: *rng_mod.Rng) EvalError!DiceRollResult {
    if (dice.count > MAX_DICE) {
        return error.TooManyDice;
    }

    var result = DiceRollResult{
        .dice_results = &[_]DieResult{},
        .subtotal = 0,
    };

    // Roll all dice
    for (0..dice.count) |i| {
        const value: u32 = if (dice.sides == 0) blk: {
            // Fudge dice: -1, 0, or +1 (we store as 0, 1, 2 and interpret later)
            // For now, just roll 1-3 and subtract 2 for display
            break :blk rng.roll(3);
        } else blk: {
            break :blk rng.roll(dice.sides);
        };

        result._dice_buf[i] = .{
            .value = value,
            .kept = true, // Will be updated by modifier
        };
    }
    result._dice_len = dice.count;
    result.dice_results = result._dice_buf[0..result._dice_len];

    // Apply modifier if present
    if (dice.modifier) |mod| {
        // Create indices array for sorting
        var indices: [MAX_DICE]usize = undefined;
        for (0..dice.count) |i| {
            indices[i] = i;
        }

        // Sort indices by die value (descending for keep_highest/drop_highest)
        const SortContext = struct {
            dice_buf: *[MAX_DICE]DieResult,

            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return ctx.dice_buf[a].value > ctx.dice_buf[b].value; // Descending
            }
        };
        std.mem.sort(usize, indices[0..dice.count], SortContext{ .dice_buf = &result._dice_buf }, SortContext.lessThan);

        // Apply modifier based on type
        switch (mod) {
            .keep_highest => |n| {
                // Keep the n highest, drop the rest
                for (indices[0..dice.count], 0..) |idx, rank| {
                    result._dice_buf[idx].kept = rank < n;
                }
            },
            .keep_lowest => |n| {
                // Keep the n lowest (last n in descending order), drop the rest
                for (indices[0..dice.count], 0..) |idx, rank| {
                    result._dice_buf[idx].kept = rank >= (dice.count - n);
                }
            },
            .drop_highest => |n| {
                // Drop the n highest (first n in descending order), keep the rest
                for (indices[0..dice.count], 0..) |idx, rank| {
                    result._dice_buf[idx].kept = rank >= n;
                }
            },
            .drop_lowest => |n| {
                // Drop the n lowest (last n in descending order), keep the rest
                for (indices[0..dice.count], 0..) |idx, rank| {
                    result._dice_buf[idx].kept = rank < (dice.count - n);
                }
            },
        }
    }

    // Calculate subtotal of kept dice
    result.subtotal = result.keptTotal();

    return result;
}

/// Evaluate an expression value (dice or number), returning the numeric result
fn evaluateValue(value: parser.ExprValue, rng: *rng_mod.Rng, roll_results: *[parser.MAX_OPERATIONS + 1]DiceRollResult, roll_count: *usize) EvalError!i32 {
    switch (value) {
        .dice => |dice| {
            const roll_result = try evaluateDiceRoll(dice, rng);
            // Store result and fix up the slice to point to the stored buffer
            roll_results[roll_count.*] = roll_result;
            roll_results[roll_count.*].dice_results = roll_results[roll_count.*]._dice_buf[0..roll_results[roll_count.*]._dice_len];
            const subtotal = roll_result.subtotal;
            roll_count.* += 1;
            return subtotal;
        },
        .number => |num| {
            return num;
        },
    }
}

/// Evaluate a complete expression
pub fn evaluate(expr: parser.Expr, rng: *rng_mod.Rng) EvalError!RollResult {
    var result = RollResult{
        .dice_rolls = &[_]DiceRollResult{},
        .total = 0,
        .has_modifiers = false,
    };
    var roll_count: usize = 0;

    // Evaluate base value
    var total = try evaluateValue(expr.base, rng, &result._rolls_buf, &roll_count);

    // Check if base has modifiers
    if (expr.base == .dice and expr.base.dice.modifier != null) {
        result.has_modifiers = true;
    }

    // Has operations means we need to show the total
    if (expr.operations.len > 0) {
        result.has_modifiers = true;
    }

    // Apply each operation
    for (expr.operations) |op| {
        const operand = try evaluateValue(op.value, rng, &result._rolls_buf, &roll_count);

        // Check if this operand has modifiers
        if (op.value == .dice and op.value.dice.modifier != null) {
            result.has_modifiers = true;
        }

        total = switch (op.op) {
            .add => std.math.add(i32, total, operand) catch return error.Overflow,
            .sub => std.math.sub(i32, total, operand) catch return error.Overflow,
            .mul => std.math.mul(i32, total, operand) catch return error.Overflow,
            .div => blk: {
                if (operand == 0) return error.DivisionByZero;
                break :blk @divTrunc(total, operand);
            },
        };
    }

    result._rolls_len = roll_count;
    result.dice_rolls = result._rolls_buf[0..result._rolls_len];
    result.total = total;

    return result;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "evaluate simple dice roll" {
    var rng = rng_mod.Rng.init(42);
    const expr = try parser.parse("2d6");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    try testing.expectEqual(@as(usize, 2), result.dice_rolls[0].dice_results.len);
    try testing.expect(!result.has_modifiers);

    // All dice should be kept
    for (result.dice_rolls[0].dice_results) |die| {
        try testing.expect(die.kept);
        try testing.expect(die.value >= 1 and die.value <= 6);
    }
}

test "evaluate dice with keep highest modifier" {
    var rng = rng_mod.Rng.init(42);
    const expr = try parser.parse("4d6k3");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    try testing.expectEqual(@as(usize, 4), result.dice_rolls[0].dice_results.len);
    try testing.expect(result.has_modifiers);

    // Exactly 3 dice should be kept
    var kept_count: usize = 0;
    for (result.dice_rolls[0].dice_results) |die| {
        if (die.kept) kept_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), kept_count);
}

test "evaluate dice with drop lowest modifier" {
    var rng = rng_mod.Rng.init(42);
    const expr = try parser.parse("4d6d1");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    try testing.expectEqual(@as(usize, 4), result.dice_rolls[0].dice_results.len);
    try testing.expect(result.has_modifiers);

    // Exactly 3 dice should be kept (1 dropped)
    var kept_count: usize = 0;
    for (result.dice_rolls[0].dice_results) |die| {
        if (die.kept) kept_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), kept_count);
}

test "evaluate dice plus number" {
    var rng = rng_mod.Rng.init(42);
    const expr = try parser.parse("2d6+5");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    try testing.expect(result.has_modifiers);

    // Total should be sum of dice plus 5
    const dice_sum = result.dice_rolls[0].subtotal;
    try testing.expectEqual(dice_sum + 5, result.total);
}

test "evaluate dice plus dice" {
    var rng = rng_mod.Rng.init(42);
    const expr = try parser.parse("2d6+1d4");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 2), result.dice_rolls.len);
    try testing.expect(result.has_modifiers);

    // Total should be sum of both dice rolls
    const total = result.dice_rolls[0].subtotal + result.dice_rolls[1].subtotal;
    try testing.expectEqual(total, result.total);
}

test "evaluate plain number" {
    var rng = rng_mod.Rng.init(42);
    const expr = try parser.parse("5");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 0), result.dice_rolls.len);
    try testing.expectEqual(@as(i32, 5), result.total);
    try testing.expect(!result.has_modifiers);
}

test "evaluate complex expression" {
    var rng = rng_mod.Rng.init(42);
    const expr = try parser.parse("4d6k3+5");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    try testing.expect(result.has_modifiers);

    // Verify kept dice count
    var kept_count: usize = 0;
    for (result.dice_rolls[0].dice_results) |die| {
        if (die.kept) kept_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), kept_count);

    // Verify total
    try testing.expectEqual(result.dice_rolls[0].subtotal + 5, result.total);
}

test "dropped dice have lowest values with drop_lowest" {
    // Use a seed that gives us known values to verify sorting
    var rng = rng_mod.Rng.init(12345);
    const expr = try parser.parse("4d6d1");
    const result = try evaluate(expr, &rng);

    // Find the dropped die and verify it has the minimum value
    var min_value: u32 = std.math.maxInt(u32);
    var dropped_value: u32 = 0;
    for (result.dice_rolls[0].dice_results) |die| {
        if (die.value < min_value) {
            min_value = die.value;
        }
        if (!die.kept) {
            dropped_value = die.value;
        }
    }
    try testing.expectEqual(min_value, dropped_value);
}

test "kept dice have highest values with keep_highest" {
    var rng = rng_mod.Rng.init(12345);
    const expr = try parser.parse("4d6k3");
    const result = try evaluate(expr, &rng);

    // Collect kept and dropped values
    var kept_min: u32 = std.math.maxInt(u32);
    var dropped_max: u32 = 0;

    for (result.dice_rolls[0].dice_results) |die| {
        if (die.kept) {
            if (die.value < kept_min) kept_min = die.value;
        } else {
            if (die.value > dropped_max) dropped_max = die.value;
        }
    }

    // All kept dice should be >= dropped dice
    try testing.expect(kept_min >= dropped_max);
}
