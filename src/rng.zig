const std = @import("std");

pub const Rng = struct {
    prng: std.Random.DefaultPrng,
    seed: u64,

    /// Initialize RNG with optional seed. If seed is null, uses OS entropy
    /// via getrandom(), falling back to timestamp if that fails.
    pub fn init(seed: ?u64) Rng {
        const actual_seed = seed orelse blk: {
            var s: u64 = undefined;
            std.posix.getrandom(std.mem.asBytes(&s)) catch {
                // Fallback to timestamp if getrandom fails
                break :blk @as(u64, @intCast(@as(u128, @bitCast(std.time.nanoTimestamp()))));
            };
            break :blk s;
        };

        return Rng{
            .prng = std.Random.DefaultPrng.init(actual_seed),
            .seed = actual_seed,
        };
    }

    /// Roll a die with the given number of sides.
    /// Returns a value from 1 to sides inclusive.
    pub fn roll(self: *Rng, sides: u32) u32 {
        return self.prng.random().intRangeAtMost(u32, 1, sides);
    }
};

test "RNG with explicit seed is reproducible" {
    var rng1 = Rng.init(12345);
    var rng2 = Rng.init(12345);
    try std.testing.expectEqual(rng1.roll(6), rng2.roll(6));
    try std.testing.expectEqual(rng1.roll(20), rng2.roll(20));
    try std.testing.expectEqual(rng1.roll(100), rng2.roll(100));
}

test "RNG without seed produces different values" {
    const rng1 = Rng.init(null);
    const rng2 = Rng.init(null);
    // Seeds should be different (extremely unlikely to be equal)
    try std.testing.expect(rng1.seed != rng2.seed);
}

test "roll returns value in range 1 to sides" {
    var rng = Rng.init(42);
    for (0..100) |_| {
        const result = rng.roll(6);
        try std.testing.expect(result >= 1 and result <= 6);
    }
}

test "roll works with various die sizes" {
    var rng = Rng.init(42);

    // Test d4
    for (0..20) |_| {
        const result = rng.roll(4);
        try std.testing.expect(result >= 1 and result <= 4);
    }

    // Test d20
    for (0..20) |_| {
        const result = rng.roll(20);
        try std.testing.expect(result >= 1 and result <= 20);
    }

    // Test d100
    for (0..20) |_| {
        const result = rng.roll(100);
        try std.testing.expect(result >= 1 and result <= 100);
    }
}
