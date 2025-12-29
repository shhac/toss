const std = @import("std");

/// Represents a dice specification parsed from notation like "2d6"
pub const DiceSpec = struct {
    count: u32,
    sides: u32,
};

/// Errors that can occur when parsing dice notation
pub const ParseError = error{
    /// No 'd' separator found in notation
    InvalidFormat,
    /// Count before 'd' is not a valid number or is zero
    InvalidCount,
    /// Sides after 'd' is not a valid number or is less than 1
    InvalidSides,
    /// Numbers are too large to represent
    Overflow,
};

/// Parse dice notation string into a DiceSpec
/// Supports formats: "2d6", "d6" (implicit count=1), "1d20"
pub fn parse(notation: []const u8) ParseError!DiceSpec {
    // Find the 'd' separator
    const d_pos = std.mem.indexOf(u8, notation, "d") orelse return error.InvalidFormat;

    // Parse count (before 'd')
    const count_str = notation[0..d_pos];
    const count: u32 = if (count_str.len == 0)
        1 // Default to 1 if no count specified (e.g., "d6")
    else
        std.fmt.parseInt(u32, count_str, 10) catch |err| switch (err) {
            error.Overflow => return error.Overflow,
            error.InvalidCharacter => return error.InvalidCount,
        };

    // Count must be at least 1
    if (count == 0) return error.InvalidCount;

    // Parse sides (after 'd')
    const sides_str = notation[d_pos + 1 ..];
    if (sides_str.len == 0) return error.InvalidSides;

    const sides = std.fmt.parseInt(u32, sides_str, 10) catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        error.InvalidCharacter => return error.InvalidSides,
    };

    // Sides must be at least 1
    if (sides == 0) return error.InvalidSides;

    return .{
        .count = count,
        .sides = sides,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parse standard notation '2d6'" {
    const spec = try parse("2d6");
    try std.testing.expectEqual(@as(u32, 2), spec.count);
    try std.testing.expectEqual(@as(u32, 6), spec.sides);
}

test "parse standard notation '1d20'" {
    const spec = try parse("1d20");
    try std.testing.expectEqual(@as(u32, 1), spec.count);
    try std.testing.expectEqual(@as(u32, 20), spec.sides);
}

test "parse implicit count 'd6'" {
    const spec = try parse("d6");
    try std.testing.expectEqual(@as(u32, 1), spec.count);
    try std.testing.expectEqual(@as(u32, 6), spec.sides);
}

test "parse large numbers '100d100'" {
    const spec = try parse("100d100");
    try std.testing.expectEqual(@as(u32, 100), spec.count);
    try std.testing.expectEqual(@as(u32, 100), spec.sides);
}

test "parse single die '1d1'" {
    const spec = try parse("1d1");
    try std.testing.expectEqual(@as(u32, 1), spec.count);
    try std.testing.expectEqual(@as(u32, 1), spec.sides);
}

test "error on missing 'd' separator" {
    const result = parse("abc");
    try std.testing.expectError(error.InvalidFormat, result);
}

test "error on empty string" {
    const result = parse("");
    try std.testing.expectError(error.InvalidFormat, result);
}

test "error on zero count '0d6'" {
    const result = parse("0d6");
    try std.testing.expectError(error.InvalidCount, result);
}

test "error on zero sides '2d0'" {
    const result = parse("2d0");
    try std.testing.expectError(error.InvalidSides, result);
}

test "error on missing sides '2d'" {
    const result = parse("2d");
    try std.testing.expectError(error.InvalidSides, result);
}

test "error on invalid count 'ad6'" {
    const result = parse("ad6");
    try std.testing.expectError(error.InvalidCount, result);
}

test "error on invalid sides '2da'" {
    const result = parse("2da");
    try std.testing.expectError(error.InvalidSides, result);
}

test "error on negative count '-1d6'" {
    // Negative numbers cause Overflow when parsing to u32
    const result = parse("-1d6");
    try std.testing.expectError(error.Overflow, result);
}

test "error on negative sides '2d-6'" {
    // Negative numbers cause Overflow when parsing to u32
    const result = parse("2d-6");
    try std.testing.expectError(error.Overflow, result);
}

test "error on overflow in count" {
    const result = parse("99999999999999999999d6");
    try std.testing.expectError(error.Overflow, result);
}

test "error on overflow in sides" {
    const result = parse("2d99999999999999999999");
    try std.testing.expectError(error.Overflow, result);
}
