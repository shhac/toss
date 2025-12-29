const std = @import("std");

// =============================================================================
// Core Types (Phase 2)
// =============================================================================

/// Maximum number of operations in an expression (e.g., 2d6+5-2+1d4 has 3 operations)
pub const MAX_OPERATIONS = 16;

/// Arithmetic operators
pub const Op = enum {
    add, // +
    sub, // -
    mul, // *
    div, // /
};

/// A value that can appear in an expression (dice roll or plain number)
pub const ExprValue = union(enum) {
    dice: DiceRoll,
    number: i32,
};

/// An operation: an operator and its right-hand operand
pub const Operation = struct {
    op: Op,
    value: ExprValue,
};

/// A complete expression: a base value followed by zero or more operations
/// Evaluated left-to-right (no operator precedence)
/// Example: 2d6+5-2 -> base=dice(2d6), operations=[{add, 5}, {sub, 2}]
pub const Expr = struct {
    base: ExprValue, // First term
    operations: []const Operation, // Subsequent operations (may be empty)
    // Internal storage for operations (used by parser)
    _operations_buf: [MAX_OPERATIONS]Operation = undefined,
    _operations_len: usize = 0,

    /// Create an expression from just a base value (no operations)
    pub fn fromValue(value: ExprValue) Expr {
        return .{
            .base = value,
            .operations = &[_]Operation{},
        };
    }

    /// Create an expression from a dice roll
    pub fn fromDice(dice: DiceRoll) Expr {
        return fromValue(.{ .dice = dice });
    }

    /// Create an expression from a number
    pub fn fromNumber(num: i32) Expr {
        return fromValue(.{ .number = num });
    }
};

// =============================================================================
// Phase 3: Modifiers
// =============================================================================

/// Dice modifiers for keep/drop operations
pub const Modifier = union(enum) {
    keep_highest: u32, // k, kh - keep highest N dice
    keep_lowest: u32, // kl - keep lowest N dice
    drop_highest: u32, // dh - drop highest N dice
    drop_lowest: u32, // d, dl - drop lowest N dice
};

/// A single dice roll specification (e.g., 2d6, 4d6kh3)
pub const DiceRoll = struct {
    count: u32, // Number of dice to roll
    sides: u32, // Number of sides (0 reserved for Fudge dice, 100 for d%)
    modifier: ?Modifier = null, // Optional keep/drop modifier
};

// =============================================================================
// Error Types
// =============================================================================

/// Parse errors with context
pub const ParseError = error{
    /// Input is empty or doesn't contain valid dice notation
    InvalidFormat,
    /// Count before 'd' is invalid (not a number or zero)
    InvalidCount,
    /// Sides after 'd' is invalid (not a number, zero, or unrecognized)
    InvalidSides,
    /// Numbers are too large
    Overflow,
    /// Unexpected character encountered
    UnexpectedCharacter,
    /// Input ended unexpectedly
    UnexpectedEndOfInput,
    /// Too many operations in expression (exceeds MAX_OPERATIONS)
    TooManyOperations,
    /// Division by zero in expression
    DivisionByZero,
    /// Modifier is invalid (e.g., keep/drop count is zero or exceeds dice count)
    InvalidModifier,
};

// =============================================================================
// Parser
// =============================================================================

const Parser = struct {
    input: []const u8,
    pos: usize,

    /// Initialize parser with input string
    pub fn init(input: []const u8) Parser {
        return .{
            .input = input,
            .pos = 0,
        };
    }

    /// Peek at current character without consuming
    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    /// Consume current character and advance
    fn advance(self: *Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        const c = self.input[self.pos];
        self.pos += 1;
        return c;
    }

    /// Check if at end of input
    fn isAtEnd(self: *Parser) bool {
        return self.pos >= self.input.len;
    }

    /// Match and consume a specific character (case insensitive for letters)
    fn matchChar(self: *Parser, expected: u8) bool {
        const c = self.peek() orelse return false;
        if (c == expected or (std.ascii.isAlphabetic(expected) and std.ascii.toLower(c) == std.ascii.toLower(expected))) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    /// Parse an unsigned integer
    fn parseUnsigned(self: *Parser) ParseError!u32 {
        const start = self.pos;

        // Consume all digits
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            _ = self.advance();
        }

        if (self.pos == start) {
            return error.UnexpectedCharacter;
        }

        const num_str = self.input[start..self.pos];
        return std.fmt.parseInt(u32, num_str, 10) catch |err| switch (err) {
            error.Overflow => return error.Overflow,
            error.InvalidCharacter => return error.UnexpectedCharacter,
        };
    }

    /// Parse dice sides (number, %, or F)
    fn parseSides(self: *Parser) ParseError!u32 {
        // Check for percentile dice (d%)
        if (self.matchChar('%')) {
            return 100;
        }

        // Check for Fudge dice (dF) - represented as 0
        if (self.matchChar('F')) {
            return 0; // 0 indicates Fudge dice
        }

        // Must be a number
        const sides = self.parseUnsigned() catch |err| switch (err) {
            error.UnexpectedCharacter => return error.InvalidSides,
            else => return err,
        };

        if (sides == 0) return error.InvalidSides;

        return sides;
    }

    /// Parse a signed integer (for standalone numbers in expressions)
    fn parseSigned(self: *Parser) ParseError!i32 {
        var negative = false;
        if (self.matchChar('-')) {
            negative = true;
        } else {
            _ = self.matchChar('+'); // Optional leading +
        }

        const unsigned = try self.parseUnsigned();

        // Convert to i32, checking for overflow
        const value: i32 = std.math.cast(i32, unsigned) orelse return error.Overflow;

        return if (negative) -value else value;
    }

    /// Try to parse an operator, returns null if no operator found
    fn parseOperator(self: *Parser) ?Op {
        const c = self.peek() orelse return null;
        const op: Op = switch (c) {
            '+' => .add,
            '-' => .sub,
            '*' => .mul,
            '/' => .div,
            else => return null,
        };
        _ = self.advance();
        return op;
    }

    /// Check if current position looks like dice notation (starts with digit+d or just d)
    fn looksLikeDice(self: *Parser) bool {
        const saved_pos = self.pos;
        defer self.pos = saved_pos;

        // Skip optional leading digits
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            _ = self.advance();
        }

        // Check for 'd' or 'D'
        if (self.peek()) |c| {
            return c == 'd' or c == 'D';
        }
        return false;
    }

    /// Parse an expression value (dice or number)
    fn parseExprValue(self: *Parser) ParseError!ExprValue {
        // Check if it looks like dice notation
        if (self.looksLikeDice()) {
            const dice = try self.parseDice();
            return .{ .dice = dice };
        }

        // Otherwise, parse as a number
        const num = try self.parseSigned();
        return .{ .number = num };
    }

    /// Parse a keep/drop modifier (k, kh, kl, d, dh, dl)
    /// Returns null if no modifier found at current position
    /// The tricky part: 'd' after sides could be drop modifier OR start of new expression
    /// We resolve this by: if 'd' is followed by a digit, it's drop modifier
    fn parseModifier(self: *Parser, dice_count: u32) ParseError!?Modifier {
        const c = self.peek() orelse return null;

        // Check for 'k' (keep) modifiers
        if (c == 'k' or c == 'K') {
            _ = self.advance();

            // Check for 'h' (high) or 'l' (low) suffix
            const next = self.peek();
            const is_lowest = if (next) |n| (n == 'l' or n == 'L') else false;

            if (is_lowest) {
                _ = self.advance(); // consume 'l'
                const count = self.parseUnsigned() catch |err| switch (err) {
                    error.UnexpectedCharacter => return error.InvalidModifier,
                    else => return err,
                };
                if (count == 0 or count > dice_count) return error.InvalidModifier;
                return .{ .keep_lowest = count };
            } else {
                // 'k' or 'kh' both mean keep highest
                if (next) |n| {
                    if (n == 'h' or n == 'H') {
                        _ = self.advance(); // consume optional 'h'
                    }
                }
                const count = self.parseUnsigned() catch |err| switch (err) {
                    error.UnexpectedCharacter => return error.InvalidModifier,
                    else => return err,
                };
                if (count == 0 or count > dice_count) return error.InvalidModifier;
                return .{ .keep_highest = count };
            }
        }

        // Check for 'd' (drop) modifiers
        // Key insight: 'd' followed by digit is drop modifier, otherwise not a modifier
        if (c == 'd' or c == 'D') {
            // Look ahead to see if this is a drop modifier or something else
            const saved_pos = self.pos;

            _ = self.advance(); // consume 'd'
            const next = self.peek();

            // Check for 'h' (high) suffix - drop highest
            if (next) |n| {
                if (n == 'h' or n == 'H') {
                    _ = self.advance(); // consume 'h'
                    const count = self.parseUnsigned() catch |err| switch (err) {
                        error.UnexpectedCharacter => {
                            // Not a valid modifier, restore position
                            self.pos = saved_pos;
                            return null;
                        },
                        else => return err,
                    };
                    if (count == 0 or count > dice_count) return error.InvalidModifier;
                    return .{ .drop_highest = count };
                }
            }

            // Check for 'l' (low) suffix or bare digit - both mean drop lowest
            if (next) |n| {
                if (n == 'l' or n == 'L') {
                    _ = self.advance(); // consume 'l'
                    const count = self.parseUnsigned() catch |err| switch (err) {
                        error.UnexpectedCharacter => {
                            // Not a valid modifier, restore position
                            self.pos = saved_pos;
                            return null;
                        },
                        else => return err,
                    };
                    if (count == 0 or count > dice_count) return error.InvalidModifier;
                    return .{ .drop_lowest = count };
                } else if (std.ascii.isDigit(n)) {
                    // 'd' followed by digit = drop lowest (e.g., 4d6d1)
                    const count = self.parseUnsigned() catch |err| switch (err) {
                        error.UnexpectedCharacter => {
                            self.pos = saved_pos;
                            return null;
                        },
                        else => return err,
                    };
                    if (count == 0 or count > dice_count) return error.InvalidModifier;
                    return .{ .drop_lowest = count };
                }
            }

            // Not a modifier (e.g., 'd' at end or followed by non-digit)
            self.pos = saved_pos;
            return null;
        }

        return null;
    }

    /// Parse a dice roll specification
    fn parseDice(self: *Parser) ParseError!DiceRoll {
        // Parse optional count
        const has_count = if (self.peek()) |c| std.ascii.isDigit(c) else false;
        const count: u32 = if (has_count) blk: {
            const c = self.parseUnsigned() catch |err| switch (err) {
                error.UnexpectedCharacter => return error.InvalidCount,
                else => return err,
            };
            if (c == 0) return error.InvalidCount;
            break :blk c;
        } else 1;

        // Expect 'd' or 'D'
        if (!self.matchChar('d')) {
            return error.InvalidFormat;
        }

        // Parse sides
        const sides = try self.parseSides();

        // Parse optional modifier (Phase 3)
        const modifier = try self.parseModifier(count);

        return .{
            .count = count,
            .sides = sides,
            .modifier = modifier,
        };
    }

    /// Parse a complete expression (Phase 2: base value with optional operations)
    fn parseExpression(self: *Parser) ParseError!Expr {
        // Parse the base value (first term)
        const base = try self.parseExprValue();

        // Create result with internal buffer
        var result = Expr{
            .base = base,
            .operations = &[_]Operation{},
        };

        // Parse subsequent operations
        while (self.parseOperator()) |op| {
            // Check for too many operations
            if (result._operations_len >= MAX_OPERATIONS) {
                return error.TooManyOperations;
            }

            // Parse the right-hand value
            const value = try self.parseExprValue();

            // Store in buffer
            result._operations_buf[result._operations_len] = .{
                .op = op,
                .value = value,
            };
            result._operations_len += 1;
        }

        // Point slice to populated portion of buffer
        result.operations = result._operations_buf[0..result._operations_len];

        return result;
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Parse a dice notation string into an expression
pub fn parse(input: []const u8) ParseError!Expr {
    if (input.len == 0) {
        return error.InvalidFormat;
    }

    var parser = Parser.init(input);
    const expr = try parser.parseExpression();

    // Ensure we consumed all input (Phase 1: no trailing characters)
    if (!parser.isAtEnd()) {
        return error.UnexpectedCharacter;
    }

    return expr;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// -----------------------------------------------------------------------------
// Test Helpers
// -----------------------------------------------------------------------------

fn expectDice(value: ExprValue, expected_count: u32, expected_sides: u32) !void {
    try testing.expect(value == .dice);
    try testing.expectEqual(expected_count, value.dice.count);
    try testing.expectEqual(expected_sides, value.dice.sides);
}

fn expectDiceWithModifier(value: ExprValue, expected_count: u32, expected_sides: u32, expected_modifier: ?Modifier) !void {
    try testing.expect(value == .dice);
    try testing.expectEqual(expected_count, value.dice.count);
    try testing.expectEqual(expected_sides, value.dice.sides);
    if (expected_modifier) |exp_mod| {
        const actual_mod = value.dice.modifier orelse {
            return error.TestExpectedEqual;
        };
        try testing.expectEqual(exp_mod, actual_mod);
    } else {
        try testing.expect(value.dice.modifier == null);
    }
}

fn expectNumber(value: ExprValue, expected: i32) !void {
    try testing.expect(value == .number);
    try testing.expectEqual(expected, value.number);
}

// -----------------------------------------------------------------------------
// Basic Dice Notation Tests
// -----------------------------------------------------------------------------

test "parse standard notation '2d6'" {
    const result = try parse("2d6");
    try expectDice(result.base, 2, 6);
    try testing.expectEqual(@as(usize, 0), result.operations.len);
}

test "parse standard notation '1d20'" {
    const result = try parse("1d20");
    try expectDice(result.base, 1, 20);
    try testing.expectEqual(@as(usize, 0), result.operations.len);
}

test "parse implicit count 'd6'" {
    const result = try parse("d6");
    try expectDice(result.base, 1, 6);
    try testing.expectEqual(@as(usize, 0), result.operations.len);
}

test "parse implicit count 'd20'" {
    const result = try parse("d20");
    try expectDice(result.base, 1, 20);
    try testing.expectEqual(@as(usize, 0), result.operations.len);
}

test "parse large numbers '100d100'" {
    const result = try parse("100d100");
    try expectDice(result.base, 100, 100);
    try testing.expectEqual(@as(usize, 0), result.operations.len);
}

test "parse single die '1d1'" {
    const result = try parse("1d1");
    try expectDice(result.base, 1, 1);
    try testing.expectEqual(@as(usize, 0), result.operations.len);
}

// -----------------------------------------------------------------------------
// Percentile Dice Tests (d% and d100)
// -----------------------------------------------------------------------------

test "parse percentile 'd%'" {
    const result = try parse("d%");
    try expectDice(result.base, 1, 100);
}

test "parse percentile '1d%'" {
    const result = try parse("1d%");
    try expectDice(result.base, 1, 100);
}

test "parse percentile '2d%'" {
    const result = try parse("2d%");
    try expectDice(result.base, 2, 100);
}

test "parse d100 same as d%" {
    const result = try parse("d100");
    try expectDice(result.base, 1, 100);
}

test "parse 2d100" {
    const result = try parse("2d100");
    try expectDice(result.base, 2, 100);
}

// -----------------------------------------------------------------------------
// Fudge Dice Tests (dF)
// -----------------------------------------------------------------------------

test "parse Fudge dice 'dF'" {
    const result = try parse("dF");
    try expectDice(result.base, 1, 0); // 0 = Fudge
}

test "parse Fudge dice 'df' (lowercase)" {
    const result = try parse("df");
    try expectDice(result.base, 1, 0);
}

test "parse Fudge dice '4dF'" {
    const result = try parse("4dF");
    try expectDice(result.base, 4, 0);
}

// -----------------------------------------------------------------------------
// Case Insensitivity Tests
// -----------------------------------------------------------------------------

test "parse uppercase D '2D6'" {
    const result = try parse("2D6");
    try expectDice(result.base, 2, 6);
}

test "parse uppercase D 'D20'" {
    const result = try parse("D20");
    try expectDice(result.base, 1, 20);
}

// -----------------------------------------------------------------------------
// Error Tests
// -----------------------------------------------------------------------------

test "error on missing 'd' separator" {
    const result = parse("abc");
    try testing.expectError(error.InvalidFormat, result);
}

test "error on empty string" {
    const result = parse("");
    try testing.expectError(error.InvalidFormat, result);
}

test "error on zero count '0d6'" {
    const result = parse("0d6");
    try testing.expectError(error.InvalidCount, result);
}

test "error on zero sides '2d0'" {
    const result = parse("2d0");
    try testing.expectError(error.InvalidSides, result);
}

test "error on missing sides '2d'" {
    const result = parse("2d");
    try testing.expectError(error.InvalidSides, result);
}

test "error on invalid count 'ad6'" {
    const result = parse("ad6");
    try testing.expectError(error.InvalidFormat, result);
}

test "error on invalid sides '2da'" {
    const result = parse("2da");
    try testing.expectError(error.InvalidSides, result);
}

test "error on just 'd'" {
    const result = parse("d");
    try testing.expectError(error.InvalidSides, result);
}

test "error on negative number followed by dice '-1d6'" {
    // -1d6 is parsed as number(-1) with trailing 'd6' which is unexpected
    const result = parse("-1d6");
    try testing.expectError(error.UnexpectedCharacter, result);
}

test "error on negative sides '2d-6'" {
    const result = parse("2d-6");
    try testing.expectError(error.InvalidSides, result);
}

test "error on overflow in count" {
    const result = parse("99999999999999999999d6");
    try testing.expectError(error.Overflow, result);
}

test "error on overflow in sides" {
    const result = parse("2d99999999999999999999");
    try testing.expectError(error.Overflow, result);
}

test "error on trailing characters '2d6x'" {
    const result = parse("2d6x");
    try testing.expectError(error.UnexpectedCharacter, result);
}

test "error on trailing space '2d6 '" {
    const result = parse("2d6 ");
    try testing.expectError(error.UnexpectedCharacter, result);
}

test "error on leading space ' 2d6'" {
    const result = parse(" 2d6");
    try testing.expectError(error.InvalidFormat, result);
}

// -----------------------------------------------------------------------------
// Phase 2: Arithmetic Expression Tests
// -----------------------------------------------------------------------------

test "parse dice plus number '2d6+5'" {
    const result = try parse("2d6+5");
    try expectDice(result.base, 2, 6);
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.add, result.operations[0].op);
    try expectNumber(result.operations[0].value, 5);
}

test "parse dice minus number '2d6-3'" {
    const result = try parse("2d6-3");
    try expectDice(result.base, 2, 6);
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.sub, result.operations[0].op);
    try expectNumber(result.operations[0].value, 3);
}

test "parse dice times number '2d6*2'" {
    const result = try parse("2d6*2");
    try expectDice(result.base, 2, 6);
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.mul, result.operations[0].op);
    try expectNumber(result.operations[0].value, 2);
}

test "parse dice divide by number '2d6/2'" {
    const result = try parse("2d6/2");
    try expectDice(result.base, 2, 6);
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.div, result.operations[0].op);
    try expectNumber(result.operations[0].value, 2);
}

test "parse dice plus dice '2d6+1d4'" {
    const result = try parse("2d6+1d4");
    try expectDice(result.base, 2, 6);
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.add, result.operations[0].op);
    try expectDice(result.operations[0].value, 1, 4);
}

test "parse dice plus dice implicit count '2d6+d4'" {
    const result = try parse("2d6+d4");
    try expectDice(result.base, 2, 6);
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.add, result.operations[0].op);
    try expectDice(result.operations[0].value, 1, 4);
}

test "parse multiple operations '2d6+5-2'" {
    const result = try parse("2d6+5-2");
    try expectDice(result.base, 2, 6);
    try testing.expectEqual(@as(usize, 2), result.operations.len);
    try testing.expectEqual(Op.add, result.operations[0].op);
    try expectNumber(result.operations[0].value, 5);
    try testing.expectEqual(Op.sub, result.operations[1].op);
    try expectNumber(result.operations[1].value, 2);
}

test "parse complex expression '1d20+5+2d4-1'" {
    const result = try parse("1d20+5+2d4-1");
    try expectDice(result.base, 1, 20);
    try testing.expectEqual(@as(usize, 3), result.operations.len);
    try testing.expectEqual(Op.add, result.operations[0].op);
    try expectNumber(result.operations[0].value, 5);
    try testing.expectEqual(Op.add, result.operations[1].op);
    try expectDice(result.operations[1].value, 2, 4);
    try testing.expectEqual(Op.sub, result.operations[2].op);
    try expectNumber(result.operations[2].value, 1);
}

test "parse number as base expression '5'" {
    const result = try parse("5");
    try expectNumber(result.base, 5);
    try testing.expectEqual(@as(usize, 0), result.operations.len);
}

test "parse number plus dice '5+2d6'" {
    const result = try parse("5+2d6");
    try expectNumber(result.base, 5);
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.add, result.operations[0].op);
    try expectDice(result.operations[0].value, 2, 6);
}

test "parse number plus number '5+3'" {
    const result = try parse("5+3");
    try expectNumber(result.base, 5);
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.add, result.operations[0].op);
    try expectNumber(result.operations[0].value, 3);
}

test "parse mixed operations '2d6*2+1d4'" {
    const result = try parse("2d6*2+1d4");
    try expectDice(result.base, 2, 6);
    try testing.expectEqual(@as(usize, 2), result.operations.len);
    try testing.expectEqual(Op.mul, result.operations[0].op);
    try expectNumber(result.operations[0].value, 2);
    try testing.expectEqual(Op.add, result.operations[1].op);
    try expectDice(result.operations[1].value, 1, 4);
}

test "error on trailing operator '2d6+'" {
    const result = parse("2d6+");
    try testing.expectError(error.UnexpectedCharacter, result);
}

test "error on double operator '2d6++5'" {
    const result = parse("2d6++5");
    // First + is parsed, then second + is the start of value parsing
    // which expects a number, but + is not a digit and not followed by digits
    try testing.expectError(error.UnexpectedCharacter, result);
}

// -----------------------------------------------------------------------------
// Phase 3: Keep/Drop Modifier Tests
// -----------------------------------------------------------------------------

// Keep Highest Tests (k, kh)

test "parse keep highest '4d6k3'" {
    const result = try parse("4d6k3");
    try expectDiceWithModifier(result.base, 4, 6, .{ .keep_highest = 3 });
    try testing.expectEqual(@as(usize, 0), result.operations.len);
}

test "parse keep highest '4d6kh3'" {
    const result = try parse("4d6kh3");
    try expectDiceWithModifier(result.base, 4, 6, .{ .keep_highest = 3 });
}

test "parse keep highest uppercase '4D6K3'" {
    const result = try parse("4D6K3");
    try expectDiceWithModifier(result.base, 4, 6, .{ .keep_highest = 3 });
}

test "parse keep highest uppercase '4D6KH3'" {
    const result = try parse("4D6KH3");
    try expectDiceWithModifier(result.base, 4, 6, .{ .keep_highest = 3 });
}

test "parse keep highest single '2d20k1'" {
    const result = try parse("2d20k1");
    try expectDiceWithModifier(result.base, 2, 20, .{ .keep_highest = 1 });
}

// Keep Lowest Tests (kl)

test "parse keep lowest '4d6kl1'" {
    const result = try parse("4d6kl1");
    try expectDiceWithModifier(result.base, 4, 6, .{ .keep_lowest = 1 });
}

test "parse keep lowest uppercase '4D6KL1'" {
    const result = try parse("4D6KL1");
    try expectDiceWithModifier(result.base, 4, 6, .{ .keep_lowest = 1 });
}

test "parse keep lowest '3d8kl2'" {
    const result = try parse("3d8kl2");
    try expectDiceWithModifier(result.base, 3, 8, .{ .keep_lowest = 2 });
}

// Drop Lowest Tests (d, dl)

test "parse drop lowest '4d6d1'" {
    const result = try parse("4d6d1");
    try expectDiceWithModifier(result.base, 4, 6, .{ .drop_lowest = 1 });
}

test "parse drop lowest '4d6dl1'" {
    const result = try parse("4d6dl1");
    try expectDiceWithModifier(result.base, 4, 6, .{ .drop_lowest = 1 });
}

test "parse drop lowest uppercase '4D6D1'" {
    const result = try parse("4D6D1");
    try expectDiceWithModifier(result.base, 4, 6, .{ .drop_lowest = 1 });
}

test "parse drop lowest uppercase '4D6DL1'" {
    const result = try parse("4D6DL1");
    try expectDiceWithModifier(result.base, 4, 6, .{ .drop_lowest = 1 });
}

test "parse drop lowest '5d10d2'" {
    const result = try parse("5d10d2");
    try expectDiceWithModifier(result.base, 5, 10, .{ .drop_lowest = 2 });
}

// Drop Highest Tests (dh)

test "parse drop highest '4d6dh1'" {
    const result = try parse("4d6dh1");
    try expectDiceWithModifier(result.base, 4, 6, .{ .drop_highest = 1 });
}

test "parse drop highest uppercase '4D6DH1'" {
    const result = try parse("4D6DH1");
    try expectDiceWithModifier(result.base, 4, 6, .{ .drop_highest = 1 });
}

test "parse drop highest '6d8dh2'" {
    const result = try parse("6d8dh2");
    try expectDiceWithModifier(result.base, 6, 8, .{ .drop_highest = 2 });
}

// Modifiers with Expressions

test "parse modifier with addition '4d6k3+5'" {
    const result = try parse("4d6k3+5");
    try expectDiceWithModifier(result.base, 4, 6, .{ .keep_highest = 3 });
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.add, result.operations[0].op);
    try expectNumber(result.operations[0].value, 5);
}

test "parse modifier with dice addition '4d6k3+1d4'" {
    const result = try parse("4d6k3+1d4");
    try expectDiceWithModifier(result.base, 4, 6, .{ .keep_highest = 3 });
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.add, result.operations[0].op);
    try expectDice(result.operations[0].value, 1, 4);
}

test "parse modifier in second dice '2d6+4d6k3'" {
    const result = try parse("2d6+4d6k3");
    try expectDice(result.base, 2, 6);
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.add, result.operations[0].op);
    try expectDiceWithModifier(result.operations[0].value, 4, 6, .{ .keep_highest = 3 });
}

test "parse both dice with modifiers '4d6k3+2d20kh1'" {
    const result = try parse("4d6k3+2d20kh1");
    try expectDiceWithModifier(result.base, 4, 6, .{ .keep_highest = 3 });
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.add, result.operations[0].op);
    try expectDiceWithModifier(result.operations[0].value, 2, 20, .{ .keep_highest = 1 });
}

test "parse drop lowest with subtraction '4d6d1-2'" {
    const result = try parse("4d6d1-2");
    try expectDiceWithModifier(result.base, 4, 6, .{ .drop_lowest = 1 });
    try testing.expectEqual(@as(usize, 1), result.operations.len);
    try testing.expectEqual(Op.sub, result.operations[0].op);
    try expectNumber(result.operations[0].value, 2);
}

// Edge Cases - Keep/Drop All or Maximum

test "parse keep all dice '4d6k4'" {
    const result = try parse("4d6k4");
    try expectDiceWithModifier(result.base, 4, 6, .{ .keep_highest = 4 });
}

test "parse drop all but one '4d6d3'" {
    const result = try parse("4d6d3");
    try expectDiceWithModifier(result.base, 4, 6, .{ .drop_lowest = 3 });
}

// Modifier Errors

test "error on keep zero '4d6k0'" {
    const result = parse("4d6k0");
    try testing.expectError(error.InvalidModifier, result);
}

test "error on keep more than count '4d6k5'" {
    const result = parse("4d6k5");
    try testing.expectError(error.InvalidModifier, result);
}

test "error on drop zero '4d6d0'" {
    const result = parse("4d6d0");
    try testing.expectError(error.InvalidModifier, result);
}

test "error on drop more than count '4d6d5'" {
    const result = parse("4d6d5");
    try testing.expectError(error.InvalidModifier, result);
}

test "error on keep lowest zero '4d6kl0'" {
    const result = parse("4d6kl0");
    try testing.expectError(error.InvalidModifier, result);
}

test "error on drop highest more than count '4d6dh5'" {
    const result = parse("4d6dh5");
    try testing.expectError(error.InvalidModifier, result);
}

test "error on missing modifier count '4d6k'" {
    const result = parse("4d6k");
    try testing.expectError(error.InvalidModifier, result);
}

test "error on missing modifier count '4d6kh'" {
    const result = parse("4d6kh");
    try testing.expectError(error.InvalidModifier, result);
}

// Verify basic dice still work (no modifier)

test "parse basic dice has no modifier '2d6'" {
    const result = try parse("2d6");
    try expectDiceWithModifier(result.base, 2, 6, null);
}

test "parse d20 has no modifier" {
    const result = try parse("d20");
    try expectDiceWithModifier(result.base, 1, 20, null);
}
