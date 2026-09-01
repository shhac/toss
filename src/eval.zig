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

/// Maximum number of reroll history entries to track (for display purposes)
pub const MAX_REROLL_HISTORY = 10;

/// Result of a single die roll
pub const DieResult = struct {
    value: u32,
    kept: bool, // false if dropped by modifier
    exploded: bool = false, // true if this die triggered an explosion
    // Reroll history (bounded array for display)
    _reroll_history: [MAX_REROLL_HISTORY]u32 = undefined,
    _reroll_count: u8 = 0,

    pub fn rerollHistory(self: *const DieResult) []const u32 {
        return self._reroll_history[0..self._reroll_count];
    }
};

/// Result of evaluating a dice roll expression (e.g., 4d6k3)
pub const DiceRollResult = struct {
    subtotal: i32, // Sum of kept dice
    sides: u32 = 0, // Number of sides (0 = Fudge dice)

    // Internal storage
    _dice_buf: [MAX_DICE]DieResult = undefined,
    _dice_len: usize = 0,

    /// Individual die values.
    /// Derived on demand so the slice survives copying the struct by value.
    pub fn diceResults(self: *const DiceRollResult) []const DieResult {
        return self._dice_buf[0..self._dice_len];
    }

    /// Append a die, ignoring the request once the fixed buffer is full.
    fn appendDie(self: *DiceRollResult, value: u32) void {
        if (self._dice_len >= MAX_DICE) return;
        self._dice_buf[self._dice_len] = .{ .value = value, .kept = true };
        self._dice_len += 1;
    }

    /// Sum of all kept dice (adjusts for Fudge dice: values 1,2,3 -> -1,0,+1)
    pub fn keptTotal(self: *const DiceRollResult) i32 {
        var total: i32 = 0;
        for (self.diceResults()) |die| {
            if (die.kept) {
                if (self.sides == 0) {
                    // Fudge dice: stored value 1,2,3 maps to -1,0,+1
                    total += @as(i32, @intCast(die.value)) - 2;
                } else {
                    total += @intCast(die.value);
                }
            }
        }
        return total;
    }
};

/// Result of evaluating a complete expression
pub const RollResult = struct {
    /// Final total after all arithmetic operations
    total: i32,
    /// Whether the expression has modifiers or arithmetic (determines if we show total)
    has_modifiers: bool,

    // Internal storage
    _rolls_buf: [parser.MAX_OPERATIONS + 1]DiceRollResult = undefined,
    _rolls_len: usize = 0,

    /// All dice roll results in the expression, in order of appearance.
    /// Derived on demand so the slice survives copying the struct by value.
    pub fn diceRolls(self: *const RollResult) []const DiceRollResult {
        return self._rolls_buf[0..self._rolls_len];
    }
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
    // A d1 always rerolls into the same value, so rerolling it never terminates
    // on its own. Fudge dice (sides == 0) reroll normally.
    if (sides == 1) return false;

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

/// Roll a single die of this specification. Fudge dice roll 1-3 and are
/// displayed as -1, 0, +1.
fn rollOne(dice: parser.DiceRoll, rng: *rng_mod.Rng) u32 {
    return rng.roll(if (dice.sides == 0) 3 else dice.sides);
}

/// Apply the explode modifier, adding or compounding dice in place.
fn applyExplode(
    result: *DiceRollResult,
    dice: parser.DiceRoll,
    config: parser.ExplodeConfig,
    rng: *rng_mod.Rng,
) void {
    var explosions: usize = 0;
    var i: usize = 0;
    while (i < result._dice_len and explosions < MAX_EXPLOSIONS) : (i += 1) {
        const die = &result._dice_buf[i];
        if (!shouldExplode(die.value, dice.sides, config)) continue;

        die.exploded = true;
        explosions += 1;
        const new_value = rollOne(dice, rng);

        switch (config.explode_type) {
            .standard => result.appendDie(new_value),
            .compound => {
                // Compound explosions fold into the same die, so chain here
                // rather than revisiting this index on a later pass.
                die.value += new_value;
                var last_value = new_value;
                while (explosions < MAX_EXPLOSIONS and
                    shouldExplode(last_value, dice.sides, config))
                {
                    last_value = rollOne(dice, rng);
                    die.value += last_value;
                    explosions += 1;
                }
            },
            // Penetrating explosions carry a -1 penalty, floored at 1.
            .penetrating => result.appendDie(if (new_value > 1) new_value - 1 else 1),
        }
    }
}

/// Apply the reroll modifier, replacing matching dice in place and recording
/// the values they replaced.
fn applyReroll(
    result: *DiceRollResult,
    dice: parser.DiceRoll,
    config: parser.RerollConfig,
    rng: *rng_mod.Rng,
) void {
    for (result._dice_buf[0..result._dice_len]) |*die| {
        var rerolls: usize = 0;
        while (rerolls < MAX_REROLLS_PER_DIE and
            shouldReroll(die.value, dice.sides, config))
        {
            if (die._reroll_count < MAX_REROLL_HISTORY) {
                die._reroll_history[die._reroll_count] = die.value;
                die._reroll_count += 1;
            }
            die.value = rollOne(dice, rng);
            rerolls += 1;
            if (config.once) break;
        }
    }
}

/// Mark which dice survive a keep/drop modifier. Pure: no RNG involved.
fn applyKeepDrop(result: *DiceRollResult, mod: parser.KeepDrop) void {
    const total = result._dice_len;

    var indices: [MAX_DICE]usize = undefined;
    for (0..total) |i| indices[i] = i;

    const SortContext = struct {
        dice_buf: *[MAX_DICE]DieResult,

        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.dice_buf[a].value > ctx.dice_buf[b].value; // Descending
        }
    };
    std.mem.sort(usize, indices[0..total], SortContext{ .dice_buf = &result._dice_buf }, SortContext.lessThan);

    // Ranks run highest-first, so every variant keeps either a prefix or a
    // suffix of that ordering -- one threshold plus a direction covers all four.
    const bounds: struct { keep_prefix: bool, threshold: usize } = switch (mod) {
        .keep_highest => |n| .{ .keep_prefix = true, .threshold = n },
        .drop_lowest => |n| .{ .keep_prefix = true, .threshold = total -| n },
        .drop_highest => |n| .{ .keep_prefix = false, .threshold = n },
        .keep_lowest => |n| .{ .keep_prefix = false, .threshold = total -| n },
    };

    for (indices[0..total], 0..) |idx, rank| {
        result._dice_buf[idx].kept = if (bounds.keep_prefix)
            rank < bounds.threshold
        else
            rank >= bounds.threshold;
    }
}

/// Evaluate a dice roll specification, applying any modifiers
fn evaluateDiceRoll(dice: parser.DiceRoll, rng: *rng_mod.Rng) EvalError!DiceRollResult {
    if (dice.count > MAX_DICE) {
        return error.TooManyDice;
    }

    var result = DiceRollResult{
        .subtotal = 0,
        .sides = dice.sides,
    };

    // Roll all initial dice
    for (0..dice.count) |i| {
        result._dice_buf[i] = .{
            .value = rollOne(dice, rng),
            .kept = true, // Will be updated by modifier
        };
    }
    result._dice_len = dice.count;

    if (dice.explode) |explode_config| applyExplode(&result, dice, explode_config, rng);
    if (dice.reroll) |reroll_config| applyReroll(&result, dice, reroll_config, rng);
    if (dice.keep_drop) |mod| applyKeepDrop(&result, mod);

    // Calculate subtotal of kept dice
    result.subtotal = result.keptTotal();

    return result;
}

/// Whether a term carries a modifier, which is what makes a total worth showing.
fn diceHasModifiers(value: parser.ExprValue) bool {
    if (value != .dice) return false;
    const dice = value.dice;
    return dice.keep_drop != null or dice.explode != null or dice.reroll != null;
}

/// Evaluate an expression value (dice or number), returning the numeric result
fn evaluateValue(value: parser.ExprValue, rng: *rng_mod.Rng, roll_results: *[parser.MAX_OPERATIONS + 1]DiceRollResult, roll_count: *usize) EvalError!i32 {
    switch (value) {
        .dice => |dice| {
            const roll_result = try evaluateDiceRoll(dice, rng);
            roll_results[roll_count.*] = roll_result;
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
        .total = 0,
        .has_modifiers = false,
    };
    var roll_count: usize = 0;

    // Evaluate base value
    var total = try evaluateValue(expr.base, rng, &result._rolls_buf, &roll_count);

    // A modifier on any term, or any arithmetic at all, means the total matters.
    if (diceHasModifiers(expr.base) or expr.operations().len > 0) {
        result.has_modifiers = true;
    }

    // Apply each operation
    for (expr.operations()) |op| {
        const operand = try evaluateValue(op.value, rng, &result._rolls_buf, &roll_count);

        if (diceHasModifiers(op.value)) result.has_modifiers = true;

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
    result.total = total;

    return result;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "evaluate simple dice roll" {
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("2d6");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expectEqual(@as(usize, 2), result.diceRolls()[0].diceResults().len);
    try testing.expect(!result.has_modifiers);

    // All dice should be kept
    for (result.diceRolls()[0].diceResults()) |die| {
        try testing.expect(die.kept);
        try testing.expect(die.value >= 1 and die.value <= 6);
    }
}

test "evaluate dice with keep highest modifier" {
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("4d6k3");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expectEqual(@as(usize, 4), result.diceRolls()[0].diceResults().len);
    try testing.expect(result.has_modifiers);

    // Exactly 3 dice should be kept
    var kept_count: usize = 0;
    for (result.diceRolls()[0].diceResults()) |die| {
        if (die.kept) kept_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), kept_count);
}

test "evaluate dice with drop lowest modifier" {
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("4d6d1");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expectEqual(@as(usize, 4), result.diceRolls()[0].diceResults().len);
    try testing.expect(result.has_modifiers);

    // Exactly 3 dice should be kept (1 dropped)
    var kept_count: usize = 0;
    for (result.diceRolls()[0].diceResults()) |die| {
        if (die.kept) kept_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), kept_count);
}

test "evaluate dice plus number" {
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("2d6+5");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expect(result.has_modifiers);

    // Total should be sum of dice plus 5
    const dice_sum = result.diceRolls()[0].subtotal;
    try testing.expectEqual(dice_sum + 5, result.total);
}

test "evaluate dice plus dice" {
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("2d6+1d4");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 2), result.diceRolls().len);
    try testing.expect(result.has_modifiers);

    // Total should be sum of both dice rolls
    const total = result.diceRolls()[0].subtotal + result.diceRolls()[1].subtotal;
    try testing.expectEqual(total, result.total);
}

test "evaluate plain number" {
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("5");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 0), result.diceRolls().len);
    try testing.expectEqual(@as(i32, 5), result.total);
    try testing.expect(!result.has_modifiers);
}

test "evaluate complex expression" {
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("4d6k3+5");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expect(result.has_modifiers);

    // Verify kept dice count
    var kept_count: usize = 0;
    for (result.diceRolls()[0].diceResults()) |die| {
        if (die.kept) kept_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), kept_count);

    // Verify total
    try testing.expectEqual(result.diceRolls()[0].subtotal + 5, result.total);
}

test "dropped dice have lowest values with drop_lowest" {
    // Use a seed that gives us known values to verify sorting
    var rng = rng_mod.Rng.init(std.testing.io, 12345);
    const expr = try parser.parse("4d6d1");
    const result = try evaluate(expr, &rng);

    // Find the dropped die and verify it has the minimum value
    var min_value: u32 = std.math.maxInt(u32);
    var dropped_value: u32 = 0;
    for (result.diceRolls()[0].diceResults()) |die| {
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
    var rng = rng_mod.Rng.init(std.testing.io, 12345);
    const expr = try parser.parse("4d6k3");
    const result = try evaluate(expr, &rng);

    // Collect kept and dropped values
    var kept_min: u32 = std.math.maxInt(u32);
    var dropped_max: u32 = 0;

    for (result.diceRolls()[0].diceResults()) |die| {
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
    var rng = rng_mod.Rng.init(std.testing.io, 1); // Seed 1 gives non-max values
    const expr = try parser.parse("1d6!");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    // If no explosion, should still have exactly 1 die
    // (we just verify the result is reasonable)
    try testing.expect(result.diceRolls()[0].diceResults().len >= 1);
    try testing.expect(result.has_modifiers);
}

test "evaluate exploding dice - with explosion" {
    // We need a seed where d6 rolls a 6 to trigger explosion
    // Let's try several seeds and find one that explodes
    const seed = try seedWhere(1000, rollsMax);
    var rng = rng_mod.Rng.init(std.testing.io, seed);
    const expr = try parser.parse("1d6!");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    // Should have more than 1 die due to explosion
    try testing.expect(result.diceRolls()[0].diceResults().len > 1);
    // First die should be marked as exploded
    try testing.expect(result.diceRolls()[0].diceResults()[0].exploded);
    try testing.expect(result.has_modifiers);
}

test "evaluate compound exploding" {
    // Find a seed where d6 rolls max to trigger compound explosion
    const seed = try seedWhere(1000, rollsMax);
    var rng = rng_mod.Rng.init(std.testing.io, seed);
    const expr = try parser.parse("1d6!!");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    // Compound explosion adds to same die, so still only 1 die result
    try testing.expectEqual(@as(usize, 1), result.diceRolls()[0].diceResults().len);
    // Die value should be > 6 (original 6 + explosion value)
    try testing.expect(result.diceRolls()[0].diceResults()[0].value > 6);
    try testing.expect(result.diceRolls()[0].diceResults()[0].exploded);
}

test "evaluate penetrating exploding" {
    // Find a seed where d6 rolls max
    const seed = try seedWhere(1000, rollsMax);
    var rng = rng_mod.Rng.init(std.testing.io, seed);
    const expr = try parser.parse("1d6!p");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    // Should have more than 1 die
    try testing.expect(result.diceRolls()[0].diceResults().len > 1);
    // First die should be marked as exploded
    try testing.expect(result.diceRolls()[0].diceResults()[0].exploded);
    // Penetrating dice get -1, so max value for additional dice is sides - 1
    for (result.diceRolls()[0].diceResults()[1..]) |die| {
        try testing.expect(die.value <= 5); // d6 - 1 = max 5
    }
}

test "exploding d1 does not explode" {
    // d1 should never explode (would be infinite loop)
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("5d1!");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    // Should still have exactly 5 dice (no explosions)
    try testing.expectEqual(@as(usize, 5), result.diceRolls()[0].diceResults().len);
    // None should be marked as exploded
    for (result.diceRolls()[0].diceResults()) |die| {
        try testing.expect(!die.exploded);
    }
}

test "exploding with compare point" {
    // Test exploding on greater than 4 (so 5 and 6 explode)
    // Find a seed where d6 rolls 5 or 6
    const seed = try seedWhere(1000, rollsAboveFour);
    var rng = rng_mod.Rng.init(std.testing.io, seed);
    const expr = try parser.parse("1d6!>4");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    // Should have more than 1 die due to explosion
    try testing.expect(result.diceRolls()[0].diceResults().len > 1);
    // First die should be > 4 and marked as exploded
    try testing.expect(result.diceRolls()[0].diceResults()[0].value > 4);
    try testing.expect(result.diceRolls()[0].diceResults()[0].exploded);
}

test "exploding with keep modifier" {
    // Test 4d6!k3 - explode on 6, then keep highest 3
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("4d6!k3");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expect(result.has_modifiers);

    // Count kept dice - should be exactly 3
    var kept_count: usize = 0;
    for (result.diceRolls()[0].diceResults()) |die| {
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
    const seed = try seedWhere(1000, rollsOne);
    var rng = rng_mod.Rng.init(std.testing.io, seed);
    const expr = try parser.parse("1d6r");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expectEqual(@as(usize, 1), result.diceRolls()[0].diceResults().len);
    // After continuous reroll, value should NOT be 1
    try testing.expect(result.diceRolls()[0].diceResults()[0].value != 1);
}

test "evaluate reroll once" {
    // Reroll 1s once - even if new value is 1, don't reroll again
    // Find a seed where d6 rolls 1 twice in a row
    const seed = try seedWhere(10000, rollsOneTwice);
    var rng = rng_mod.Rng.init(std.testing.io, seed);
    const expr = try parser.parse("1d6ro");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expectEqual(@as(usize, 1), result.diceRolls()[0].diceResults().len);
    // With ro we reroll only once, so two 1s in a row still leave the die at 1.
    try testing.expectEqual(@as(u32, 1), result.diceRolls()[0].diceResults()[0].value);
}

test "evaluate reroll less than" {
    // Reroll values < 3 (i.e., 1 and 2)
    // Find a seed where first roll is 1 or 2
    const seed = try seedWhere(1000, rollsBelowThree);
    var rng = rng_mod.Rng.init(std.testing.io, seed);
    const expr = try parser.parse("1d6r<3");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expectEqual(@as(usize, 1), result.diceRolls()[0].diceResults().len);
    // After reroll, value should be >= 3
    try testing.expect(result.diceRolls()[0].diceResults()[0].value >= 3);
}

test "evaluate reroll with keep/drop" {
    // 4d6r1k3 - reroll 1s, then keep highest 3
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("4d6r1k3");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expectEqual(@as(usize, 4), result.diceRolls()[0].diceResults().len);

    // Verify exactly 3 dice are kept
    var kept_count: usize = 0;
    for (result.diceRolls()[0].diceResults()) |die| {
        if (die.kept) kept_count += 1;
        // No die should be a 1 after rerolling (unless reroll cap was hit, which is unlikely)
        // Actually, with r1 (explicit), 1s should be rerolled until not 1
        // But test may have a die that wasn't 1 to begin with
    }
    try testing.expectEqual(@as(usize, 3), kept_count);
}

test "evaluate reroll with explode" {
    // 4d6!r1 - explode on 6, then reroll 1s
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("4d6!r1");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    // Should have at least 4 dice (maybe more if explosions happened)
    try testing.expect(result.diceRolls()[0].diceResults().len >= 4);
}

// -----------------------------------------------------------------------------
// Fudge Dice Tests
// -----------------------------------------------------------------------------

test "evaluate Fudge dice values in range" {
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    const expr = try parser.parse("4dF");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expectEqual(@as(usize, 4), result.diceRolls()[0].diceResults().len);

    // Fudge dice should produce values 1, 2, or 3 (displayed as -1, 0, +1)
    for (result.diceRolls()[0].diceResults()) |die| {
        try testing.expect(die.value >= 1 and die.value <= 3);
    }
}

test "evaluate Fudge dice total is sum minus 2 per die" {
    var rng = rng_mod.Rng.init(std.testing.io, 12345);
    const expr = try parser.parse("4dF");
    const result = try evaluate(expr, &rng);

    // Calculate expected total: sum of (value - 2) for each die
    var expected_total: i32 = 0;
    for (result.diceRolls()[0].diceResults()) |die| {
        expected_total += @as(i32, @intCast(die.value)) - 2;
    }
    try testing.expectEqual(expected_total, result.total);
}

// -----------------------------------------------------------------------------
// Reroll History Tests
// -----------------------------------------------------------------------------

test "reroll tracks history" {
    // Find a seed where d6 rolls 1 first (triggering reroll on r1)
    const seed = try seedWhere(1000, rollsOne);

    var rng = rng_mod.Rng.init(std.testing.io, seed);
    const expr = try parser.parse("1d6r1");
    const result = try evaluate(expr, &rng);

    try testing.expectEqual(@as(usize, 1), result.diceRolls().len);
    try testing.expectEqual(@as(usize, 1), result.diceRolls()[0].diceResults().len);

    const die = &result.diceRolls()[0].diceResults()[0];
    // Should have at least one reroll in history (the initial 1 that was rerolled)
    try testing.expect(die._reroll_count > 0);
    // First history entry should be the rerolled value (1)
    try testing.expectEqual(@as(u32, 1), die.rerollHistory()[0]);
    // Final value should NOT be 1 (rerolled away)
    try testing.expect(die.value != 1);
}

test "reroll history respects MAX_REROLL_HISTORY cap" {
    // Test that history is capped at MAX_REROLL_HISTORY
    // Use a d2 with reroll on 1 - this will reroll until we get 2
    // With a bad seed this could reroll many times
    var seed: u64 = 0;
    var max_rerolls: usize = 0;
    // Find a seed that causes many rerolls on d2r1
    while (seed < 10000) : (seed += 1) {
        var test_rng = rng_mod.Rng.init(std.testing.io, seed);
        var count: usize = 0;
        while (test_rng.roll(2) == 1 and count < 20) {
            count += 1;
        }
        if (count > max_rerolls) {
            max_rerolls = count;
        }
        if (count > MAX_REROLL_HISTORY) {
            break; // Found a seed with many rerolls
        }
    }

    // Even if many rerolls happened, history should be capped
    var rng = rng_mod.Rng.init(std.testing.io, seed);
    const expr = try parser.parse("1d2r1");
    const result = try evaluate(expr, &rng);

    const die = &result.diceRolls()[0].diceResults()[0];
    // History count should never exceed MAX_REROLL_HISTORY
    try testing.expect(die._reroll_count <= MAX_REROLL_HISTORY);
}

// =============================================================================
// Buffer bounds and RNG-free modifier logic
// =============================================================================

/// Search for a seed whose opening rolls satisfy `pred`. Fails loudly when no
/// seed in `bound` matches -- otherwise an exhausted search would leave the
/// assertions running against a seed that never met the condition.
fn seedWhere(bound: u64, pred: *const fn (*rng_mod.Rng) bool) !u64 {
    var seed: u64 = 0;
    while (seed < bound) : (seed += 1) {
        var rng = rng_mod.Rng.init(std.testing.io, seed);
        if (pred(&rng)) return seed;
    }
    return error.NoSeedSatisfiesPredicate;
}

fn rollsMax(rng: *rng_mod.Rng) bool {
    return rng.roll(6) == 6;
}
fn rollsAboveFour(rng: *rng_mod.Rng) bool {
    return rng.roll(6) > 4;
}
fn rollsOne(rng: *rng_mod.Rng) bool {
    return rng.roll(6) == 1;
}
fn rollsBelowThree(rng: *rng_mod.Rng) bool {
    return rng.roll(6) < 3;
}
fn rollsOneTwice(rng: *rng_mod.Rng) bool {
    return rng.roll(6) == 1 and rng.roll(6) == 1;
}

fn resultWithValues(values: []const u32) DiceRollResult {
    var result = DiceRollResult{ .subtotal = 0, .sides = 6 };
    for (values) |v| result.appendDie(v);
    return result;
}

/// Kept die values in buffer order, for comparing against an expected set.
fn keptValues(result: *const DiceRollResult, buf: []u32) []const u32 {
    var n: usize = 0;
    for (result.diceResults()) |die| {
        if (die.kept) {
            buf[n] = die.value;
            n += 1;
        }
    }
    return buf[0..n];
}

fn expectKept(expected: []const u32, values: []const u32, mod: parser.KeepDrop) !void {
    var result = resultWithValues(values);
    applyKeepDrop(&result, mod);
    var buf: [MAX_DICE]u32 = undefined;
    try testing.expectEqualSlices(u32, expected, keptValues(&result, &buf));
}

test "applyKeepDrop keeps the highest n" {
    try expectKept(&.{ 6, 4 }, &.{ 3, 1, 6, 4 }, .{ .keep_highest = 2 });
}

test "applyKeepDrop keeps the lowest n" {
    try expectKept(&.{ 3, 1 }, &.{ 3, 1, 6, 4 }, .{ .keep_lowest = 2 });
}

test "applyKeepDrop drops the highest n" {
    try expectKept(&.{ 3, 1, 4 }, &.{ 3, 1, 6, 4 }, .{ .drop_highest = 1 });
}

test "applyKeepDrop drops the lowest n" {
    try expectKept(&.{ 3, 6, 4 }, &.{ 3, 1, 6, 4 }, .{ .drop_lowest = 1 });
}

test "applyKeepDrop keeping every die drops nothing" {
    try expectKept(&.{ 3, 1, 6, 4 }, &.{ 3, 1, 6, 4 }, .{ .keep_highest = 4 });
    try expectKept(&.{ 3, 1, 6, 4 }, &.{ 3, 1, 6, 4 }, .{ .drop_lowest = 0 });
}

test "applyKeepDrop breaks ties by buffer order" {
    // Two 5s: keeping one highest must keep exactly one of them.
    try expectKept(&.{5}, &.{ 5, 5, 2 }, .{ .keep_highest = 1 });
}

test "evaluate rejects more dice than the buffer holds" {
    var rng = rng_mod.Rng.init(std.testing.io, 42);

    var at_limit = try parser.parse("256d6");
    const ok = try evaluate(at_limit, &rng);
    try testing.expectEqual(@as(usize, MAX_DICE), ok.diceRolls()[0].diceResults().len);

    var over_limit = try parser.parse("257d6");
    try testing.expectError(error.TooManyDice, evaluate(over_limit, &rng));

    _ = &at_limit;
    _ = &over_limit;
}

test "shouldReroll never rerolls a d1" {
    // A d1 always rolls 1, so rerolling it could never terminate on its own.
    try testing.expect(!shouldReroll(1, 1, .{}));
    // Fudge dice (sides == 0) still reroll normally.
    try testing.expect(shouldReroll(1, 0, .{}));
    try testing.expect(shouldReroll(1, 6, .{}));
}

test "compound explosions chain and stay marked as exploded" {
    // Seed 5 rolls 6 then 6 then 3 on a d6.
    var rng = rng_mod.Rng.init(std.testing.io, 5);
    const expr = try parser.parse("1d6!!");
    const result = try evaluate(expr, &rng);

    const dice = result.diceRolls()[0].diceResults();
    try testing.expectEqual(@as(usize, 1), dice.len);
    try testing.expectEqual(@as(u32, 15), dice[0].value);
    try testing.expect(dice[0].exploded);
}

// =============================================================================
// Arithmetic errors and loop-termination caps
// =============================================================================

fn evalNotation(notation: []const u8, seed: u64) EvalError!RollResult {
    var rng = rng_mod.Rng.init(std.testing.io, seed);
    const expr = parser.parse(notation) catch |err|
        std.debug.panic("test notation '{s}' failed to parse: {t}", .{ notation, err });
    return evaluate(expr, &rng);
}

test "evaluate reports division by zero" {
    try testing.expectError(error.DivisionByZero, evalNotation("1d6/0", 42));
    try testing.expectError(error.DivisionByZero, evalNotation("10/0", 42));
}

test "evaluate reports arithmetic overflow" {
    try testing.expectError(error.Overflow, evalNotation("2147483647+2147483647", 42));
    try testing.expectError(error.Overflow, evalNotation("-2147483647-2147483647", 42));
    try testing.expectError(error.Overflow, evalNotation("2147483647*2", 42));
}

test "evaluate divides truncating toward zero" {
    const result = try evalNotation("7/2", 42);
    try testing.expectEqual(@as(i32, 3), result.total);
}

test "applyExplode stops at the explosion cap" {
    // Explode on any value: every die qualifies, so only the cap can end this.
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    var result = DiceRollResult{ .subtotal = 0, .sides = 6 };
    result.appendDie(6);

    const always: parser.ExplodeConfig = .{
        .explode_type = .standard,
        .compare = .{ .op = .gte, .value = 1 },
    };
    applyExplode(&result, .{ .count = 1, .sides = 6 }, always, &rng);

    // Each explosion appends one die, so the run is bounded by MAX_EXPLOSIONS.
    try testing.expectEqual(@as(usize, MAX_EXPLOSIONS + 1), result._dice_len);
}

test "applyExplode never exceeds the dice buffer" {
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    var result = DiceRollResult{ .subtotal = 0, .sides = 6 };
    for (0..MAX_DICE) |_| result.appendDie(6);
    try testing.expectEqual(@as(usize, MAX_DICE), result._dice_len);

    const always: parser.ExplodeConfig = .{
        .explode_type = .standard,
        .compare = .{ .op = .gte, .value = 1 },
    };
    applyExplode(&result, .{ .count = MAX_DICE, .sides = 6 }, always, &rng);

    // The buffer is already full, so explosions are dropped rather than
    // overflowing it.
    try testing.expectEqual(@as(usize, MAX_DICE), result._dice_len);
}

test "applyReroll stops at the reroll cap" {
    // Reroll on any value: the cap is the only thing that can end this.
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    var result = DiceRollResult{ .subtotal = 0, .sides = 6 };
    result.appendDie(3);

    const always: parser.RerollConfig = .{ .compare = .{ .op = .gte, .value = 1 } };
    applyReroll(&result, .{ .count = 1, .sides = 6 }, always, &rng);

    // History is capped well below the reroll cap, so it saturates.
    try testing.expectEqual(@as(u8, MAX_REROLL_HISTORY), result._dice_buf[0]._reroll_count);
    try testing.expectEqual(@as(usize, MAX_REROLL_HISTORY), result._dice_buf[0].rerollHistory().len);
}

test "reroll once replaces a die at most once" {
    var rng = rng_mod.Rng.init(std.testing.io, 42);
    var result = DiceRollResult{ .subtotal = 0, .sides = 6 };
    result.appendDie(1);

    const once: parser.RerollConfig = .{ .once = true, .compare = .{ .op = .gte, .value = 1 } };
    applyReroll(&result, .{ .count = 1, .sides = 6 }, once, &rng);

    try testing.expectEqual(@as(u8, 1), result._dice_buf[0]._reroll_count);
}

test "fudge dice never explode" {
    // Same guard that blocks d1, but for the sides == 0 sentinel.
    try testing.expect(!shouldExplode(3, 0, .{}));
    try testing.expect(!shouldExplode(1, 1, .{}));
    try testing.expect(shouldExplode(6, 6, .{}));
}
