#!/bin/bash
set -e

echo "=== Toss CLI Release Build ==="
echo ""

# Run tests first
echo "Running tests..."
zig build test
echo "All tests passed!"
echo ""

# Build release binary
echo "Building ReleaseSmall binary..."
zig build -Doptimize=ReleaseSmall

# Show binary info
echo ""
echo "Binary info:"
ls -lh zig-out/bin/toss
file zig-out/bin/toss
echo ""

# Test the binary
echo "Testing binary..."
./zig-out/bin/toss --help
echo ""

echo "Testing dice roll..."
./zig-out/bin/toss --show-seed 2d6 1d4
echo ""

echo "=== Release build complete! ==="
echo "Binary at: zig-out/bin/toss"
