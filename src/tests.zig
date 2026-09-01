//! Test entry point. Zig only discovers `test` blocks in the root source file,
//! so every module must be referenced here to be included in `zig build test`.

test {
    _ = @import("main.zig");
    _ = @import("cli.zig");
    _ = @import("render.zig");
    _ = @import("parser.zig");
    _ = @import("eval.zig");
    _ = @import("rng.zig");
}
