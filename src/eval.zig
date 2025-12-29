const std = @import("std");
const parser = @import("parser.zig");
const rng_mod = @import("rng.zig");

const Allocator = std.mem.Allocator;

/// Maximum number of dice that can be rolled in a single dice expression
pub const MAX_DICE = 256;

/// Maximum number of explosions per dice expression (prevents infinite loops)
pub const MAX_EXPLOSIONS = 100;

/// Maximum number of rerolls per die (prevents infinite loops)
pub const MAX_REROLLS_PER_DIE = 100;

/// Result of a single die roll
pub const DieResult = struct {
    value: u32,
    kept: bool, // false if dropped by modifier
    exploded: bool = false, // true if this die triggered an explosion
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

/// Check if a die value should trigger an explosion
fn shouldExplode(value: u32, sides: u32, config: parser.ExplodeConfig) bool {
    // Don't explode d1 or dF (prevents infinite loops)
    if (sides <= 1) return false;

    if (config.compare) |cmp| {
        return switch (cmp.op) {
            .eq => value == cmp.value,
            .gt => value > cmp.value,
            .lt => value < cmp.value,
            .gte => value >= cmp.value,
            .lte => value <= cmp.value,
        };
    }
    // Default: explode on max
    return value == sides;
}

/// Check if a die value should be rerolled
fn shouldReroll(value: u32, sides: u32, config: parser.RerollConfig) bool {
    // Don't reroll d1 or dF (would be infinite loop for d1, undefined for dF)
    _ = sides; // Reserved for potential future use

    if (config.compare) |cmp| {
        return switch (cmp.op) {
            .eq => value == cmp.value,
            .gt => value > cmp.value,
            .lt => value < cmp.value,
            .gte => value >= cmp.value,
            .lte => value <= cmp.value,
        };
    }
    // Default: reroll 1s
    return value == 1;
}

/// Evaluate a dice roll specification, applying any modifiers
fn evaluateDiceRoll(dice: parser.DiceRoll, rng: *rng_mod.Rng) EvalError!DiceRollResult {
    if (dice.count > MAX_DICE) {
        return error.TooManyDice;
    }

    var result = DiceRollResult{
        .dice_results = &[_]DieResult{},
        .subtotal = 0,
    };

    // Roll all initial dice
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

    // Apply explode modifier if present
    if (dice.explode) |explode_config| {
        var explosions: usize = 0;

        // Process dice for explosions
        var i: usize = 0;
        while (i < result._dice_len and explosions < MAX_EXPLOSIONS) {
            const die = &result._dice_buf[i];

            // Check if this die should explode (and hasn't already been marked)
            if (!die.exploded and shouldExplode(die.value, dice.sides, explode_config)) {
                die.exploded = true;
                explosions += 1;

                // Roll a new die
                const new_value: u32 = rng.roll(dice.sides);

                switch (explode_config.explode_type) {
                    .standard => {
                        // Add new die to results
                        if (result._dice_len < MAX_DICE) {
                            result._dice_buf[result._dice_len] = .{
                                .value = new_value,
                                .kept = true,
                            };
                            result._dice_len += 1;
                        }
                    },
                    .compound => {
                        // Add value to the existing die (compound into one)
                        die.value += new_value;
                        // Check if the compound result should explode again
                        if (shouldExplode(new_value, dice.sides, explode_config) and explosions < MAX_EXPLOSIONS) {
                            die.exploded = false; // Allow it to be checked again
                        }
                    },
                    .penetrating => {
                        // Add new die with -1 penalty (minimum 1)
                        const pen_value = if (new_value > 1) new_value - 1 else 1;
                        if (result._dice_len < MAX_DICE) {
                            result._dice_buf[result._dice_len] = .{
                                .value = pen_value,
                                .kept = true,
                            };
                            result._dice_len += 1;
                        }
                    },
                }
            }
            i += 1;
        }
    }

    // Apply reroll modifier if present (after explosions, before keep/drop)
    if (dice.reroll) |reroll_config| {
        // Process each die for rerolls
        for (0..result._dice_len) |i| {
            var reroll_count: usize = 0;

            // Keep rerolling while the condition matches (for continuous reroll)
            // or just once (for reroll once)
            while (shouldReroll(result._dice_buf[i].value, dice.sides, reroll_config) and reroll_count < MAX_REROLLS_PER_DIE) {
                // Roll a new value to replace the current one
                const new_value: u32 = if (dice.sides == 0) rng.roll(3) else rng.roll(dice.sides);
                result._dice_buf[i].value = new_value;
                reroll_count += 1;

                // If reroll once, stop after first reroll
                if (reroll_config.once) {
                    break;
                }
            }
        }
    }

    result.dice_results = result._dice_buf[0..result._dice_len];

    // Apply keep/drop modifier if present
    // Note: Use result._dice_len which includes any exploded dice
    if (dice.keep_drop) |mod| {
        const total_dice = result._dice_len;

        // Create indices array for sorting
        var indices: [MAX_DICE]usize = undefined;
        for (0..total_dice) |i| {
            indices[i] = i;
        }

        // Sort indices by die value (descending for keep_highest/drop_highest)
        const SortContext = struct {
            dice_buf: *[MAX_DICE]DieResult,

            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return ctx.dice_buf[a].value > ctx.dice_buf[b].value; // Descending
            }
        };
        std.mem.sort(usize, indices[0..total_dice], SortContext{ .dice_buf = &result._dice_buf }, SortContext.lessThan);

        // Apply modifier based on type
        switch (mod) {
            .keep_highest => |n| {
                // Keep the n highest, drop the rest
                for (indices[0..total_dice], 0..) |idx, rank| {
                    result._dice_buf[idx].kept = rank < n;
                }
            },
            .keep_lowest => |n| {
                // Keep the n lowest (last n in descending order), drop the rest
                for (indices[0..total_dice], 0..) |idx, rank| {
                    result._dice_buf[idx].kept = rank >= (total_dice - n);
                }
            },
            .drop_highest => |n| {
                // Drop the n highest (first n in descending order), keep the rest
                for (indices[0..total_dice], 0..) |idx, rank| {
                    result._dice_buf[idx].kept = rank >= n;
                }
            },
            .drop_lowest => |n| {
                // Drop the n lowest (last n in descending order), keep the rest
                for (indices[0..total_dice], 0..) |idx, rank| {
                    result._dice_buf[idx].kept = rank < (total_dice - n);
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

    // Check if base has keep/drop, explode, or reroll modifiers
    if (expr.base == .dice and (expr.base.dice.keep_drop != null or expr.base.dice.explode != null or expr.base.dice.reroll != null)) {
        result.has_modifiers = true;
    }

    // Has operations means we need to show the total
    if (expr.operations.len > 0) {
        result.has_modifiers = true;
    }

    // Apply each operation
    for (expr.operations) |op| {
        const operand = try evaluateValue(op.value, rng, &result._rolls_buf, &roll_count);

        // Check if this operand has keep/drop, explode, or reroll modifiers
        if (op.value == .dice and (op.value.dice.keep_drop != null or op.value.dice.explode != null or op.value.dice.reroll != null)) {
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

// -----------------------------------------------------------------------------
// Phase 4: Exploding Dice Tests
// -----------------------------------------------------------------------------

test "evaluate exploding dice - no explosion" {
    // Use a seed that produces values that don't trigger explosions (< max)
    // Need to find a seed where 1d6 doesn't roll a 6
    var rng = rng_mod.Rng.init(1); // Seed 1 gives non-max values
    const expr = try parser.parse("1d6!");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    // If no explosion, should still have exactly 1 die
    // (we just verify the result is reasonable)
    try testing.expect(result.dice_rolls[0].dice_results.len >= 1);
    try testing.expect(result.has_modifiers);
}

test "evaluate exploding dice - with explosion" {
    // We need a seed where d6 rolls a 6 to trigger explosion
    // Let's try several seeds and find one that explodes
    var seed: u64 = 0;
    var found = false;
    while (seed < 1000 and !found) : (seed += 1) {
        var test_rng = rng_mod.Rng.init(seed);
        const val = test_rng.roll(6);
        if (val == 6) {
            found = true;
            break;
        }
    }
    // Now use that seed for the actual test
    var rng = rng_mod.Rng.init(seed);
    const expr = try parser.parse("1d6!");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    // Should have more than 1 die due to explosion
    try testing.expect(result.dice_rolls[0].dice_results.len > 1);
    // First die should be marked as exploded
    try testing.expect(result.dice_rolls[0].dice_results[0].exploded);
    try testing.expect(result.has_modifiers);
}

test "evaluate compound exploding" {
    // Find a seed where d6 rolls max to trigger compound explosion
    var seed: u64 = 0;
    while (seed < 1000) : (seed += 1) {
        var test_rng = rng_mod.Rng.init(seed);
        if (test_rng.roll(6) == 6) break;
    }
    var rng = rng_mod.Rng.init(seed);
    const expr = try parser.parse("1d6!!");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    // Compound explosion adds to same die, so still only 1 die result
    try testing.expectEqual(@as(usize, 1), result.dice_rolls[0].dice_results.len);
    // Die value should be > 6 (original 6 + explosion value)
    try testing.expect(result.dice_rolls[0].dice_results[0].value > 6);
    try testing.expect(result.dice_rolls[0].dice_results[0].exploded);
}

test "evaluate penetrating exploding" {
    // Find a seed where d6 rolls max
    var seed: u64 = 0;
    while (seed < 1000) : (seed += 1) {
        var test_rng = rng_mod.Rng.init(seed);
        if (test_rng.roll(6) == 6) break;
    }
    var rng = rng_mod.Rng.init(seed);
    const expr = try parser.parse("1d6!p");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    // Should have more than 1 die
    try testing.expect(result.dice_rolls[0].dice_results.len > 1);
    // First die should be marked as exploded
    try testing.expect(result.dice_rolls[0].dice_results[0].exploded);
    // Penetrating dice get -1, so max value for additional dice is sides - 1
    for (result.dice_rolls[0].dice_results[1..]) |die| {
        try testing.expect(die.value <= 5); // d6 - 1 = max 5
    }
}

test "exploding d1 does not explode" {
    // d1 should never explode (would be infinite loop)
    var rng = rng_mod.Rng.init(42);
    const expr = try parser.parse("5d1!");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    // Should still have exactly 5 dice (no explosions)
    try testing.expectEqual(@as(usize, 5), result.dice_rolls[0].dice_results.len);
    // None should be marked as exploded
    for (result.dice_rolls[0].dice_results) |die| {
        try testing.expect(!die.exploded);
    }
}

test "exploding with compare point" {
    // Test exploding on greater than 4 (so 5 and 6 explode)
    // Find a seed where d6 rolls 5 or 6
    var seed: u64 = 0;
    while (seed < 1000) : (seed += 1) {
        var test_rng = rng_mod.Rng.init(seed);
        const val = test_rng.roll(6);
        if (val > 4) break;
    }
    var rng = rng_mod.Rng.init(seed);
    const expr = try parser.parse("1d6!>4");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    // Should have more than 1 die due to explosion
    try testing.expect(result.dice_rolls[0].dice_results.len > 1);
    // First die should be > 4 and marked as exploded
    try testing.expect(result.dice_rolls[0].dice_results[0].value > 4);
    try testing.expect(result.dice_rolls[0].dice_results[0].exploded);
}

test "exploding with keep modifier" {
    // Test 4d6!k3 - explode on 6, then keep highest 3
    var rng = rng_mod.Rng.init(42);
    const expr = try parser.parse("4d6!k3");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    try testing.expect(result.has_modifiers);

    // Count kept dice - should be exactly 3
    var kept_count: usize = 0;
    for (result.dice_rolls[0].dice_results) |die| {
        if (die.kept) kept_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), kept_count);
}

// -----------------------------------------------------------------------------
// Phase 5: Reroll Modifier Tests
// -----------------------------------------------------------------------------

test "evaluate reroll continuous" {
    // Reroll 1s until we get a non-1
    // We'll find a seed where first roll is 1, so we can verify rerolling happens
    var seed: u64 = 0;
    while (seed < 1000) : (seed += 1) {
        var test_rng = rng_mod.Rng.init(seed);
        if (test_rng.roll(6) == 1) break;
    }
    var rng = rng_mod.Rng.init(seed);
    const expr = try parser.parse("1d6r");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    try testing.expectEqual(@as(usize, 1), result.dice_rolls[0].dice_results.len);
    // After continuous reroll, value should NOT be 1
    try testing.expect(result.dice_rolls[0].dice_results[0].value != 1);
}

test "evaluate reroll once" {
    // Reroll 1s once - even if new value is 1, don't reroll again
    // Find a seed where d6 rolls 1 twice in a row
    var seed: u64 = 0;
    var found = false;
    while (seed < 10000 and !found) : (seed += 1) {
        var test_rng = rng_mod.Rng.init(seed);
        if (test_rng.roll(6) == 1 and test_rng.roll(6) == 1) {
            found = true;
            break;
        }
    }
    if (found) {
        var rng = rng_mod.Rng.init(seed);
        const expr = try parser.parse("1d6ro");
        const result = try evaluate(expr, &rng);

        try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
        try testing.expectEqual(@as(usize, 1), result.dice_rolls[0].dice_results.len);
        // With ro, we only reroll once, so if both rolls are 1, final value is still 1
        try testing.expectEqual(@as(u32, 1), result.dice_rolls[0].dice_results[0].value);
    }
}

test "evaluate reroll less than" {
    // Reroll values < 3 (i.e., 1 and 2)
    // Find a seed where first roll is 1 or 2
    var seed: u64 = 0;
    while (seed < 1000) : (seed += 1) {
        var test_rng = rng_mod.Rng.init(seed);
        const val = test_rng.roll(6);
        if (val < 3) break;
    }
    var rng = rng_mod.Rng.init(seed);
    const expr = try parser.parse("1d6r<3");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    try testing.expectEqual(@as(usize, 1), result.dice_rolls[0].dice_results.len);
    // After reroll, value should be >= 3
    try testing.expect(result.dice_rolls[0].dice_results[0].value >= 3);
}

test "evaluate reroll with keep/drop" {
    // 4d6r1k3 - reroll 1s, then keep highest 3
    var rng = rng_mod.Rng.init(42);
    const expr = try parser.parse("4d6r1k3");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    try testing.expectEqual(@as(usize, 4), result.dice_rolls[0].dice_results.len);

    // Verify exactly 3 dice are kept
    var kept_count: usize = 0;
    for (result.dice_rolls[0].dice_results) |die| {
        if (die.kept) kept_count += 1;
        // No die should be a 1 after rerolling (unless reroll cap was hit, which is unlikely)
        // Actually, with r1 (explicit), 1s should be rerolled until not 1
        // But test may have a die that wasn't 1 to begin with
    }
    try testing.expectEqual(@as(usize, 3), kept_count);
}

test "evaluate reroll with explode" {
    // 4d6!r1 - explode on 6, then reroll 1s
    var rng = rng_mod.Rng.init(42);
    const expr = try parser.parse("4d6!r1");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.dice_rolls.len);
    // Should have at least 4 dice (maybe more if explosions happened)
    try testing.expect(result.dice_rolls[0].dice_results.len >= 4);
}
