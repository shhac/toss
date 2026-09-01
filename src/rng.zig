const std = @import("std");

pub const Rng = struct {
    prng: std.Random.DefaultPrng,
    seed: u64,

    /// Initialize RNG with optional seed. If seed is null, seeds from the
    /// `Io` implementation's entropy source.
    pub fn init(io: std.Io, seed: ?u64) Rng {
        const actual_seed = seed orelse blk: {
            var s: u64 = undefined;
            io.random(std.mem.asBytes(&s));
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
    var rng1 = Rng.init(std.testing.io, 12345);
    var rng2 = Rng.init(std.testing.io, 12345);
    try std.testing.expectEqual(rng1.roll(6), rng2.roll(6));
    try std.testing.expectEqual(rng1.roll(20), rng2.roll(20));
    try std.testing.expectEqual(rng1.roll(100), rng2.roll(100));
}

test "RNG without seed produces different values" {
    const rng1 = Rng.init(std.testing.io, null);
    const rng2 = Rng.init(std.testing.io, null);
    // Seeds should be different (extremely unlikely to be equal)
    try std.testing.expect(rng1.seed != rng2.seed);
}

test "roll returns value in range 1 to sides" {
    var rng = Rng.init(std.testing.io, 42);
    for (0..100) |_| {
        const result = rng.roll(6);
        try std.testing.expect(result >= 1 and result <= 6);
    }
}

test "roll works with various die sizes" {
    var rng = Rng.init(std.testing.io, 42);

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
