#!/bin/bash
set -e

VERSION="0.5.0"

# Target platforms
TARGETS=(
    "x86_64-linux-gnu"
    "aarch64-linux-gnu"
    "x86_64-macos"
    "aarch64-macos"
    "x86_64-windows"
)

echo "=== Toss CLI Release Build v${VERSION} ==="
echo ""

# Run tests first
echo "Running tests..."
zig build test
echo "All tests passed!"
echo ""

# Clean and create dist directory
rm -rf dist
mkdir -p dist

# Build for each target
for target in "${TARGETS[@]}"; do
    echo "Building for ${target}..."

    # Clean previous build
    rm -rf zig-out

    # Build with cross-compilation
    zig build -Doptimize=ReleaseSmall -Dtarget="${target}"

    # Determine binary name and archive type
    if [[ "${target}" == *"windows"* ]]; then
        binary_name="toss.exe"
        archive_name="toss-${VERSION}-${target}.zip"
    else
        binary_name="toss"
        archive_name="toss-${VERSION}-${target}.tar.gz"
    fi

    # Create staging directory
    staging_dir="dist/toss-${VERSION}-${target}"
    mkdir -p "${staging_dir}"

    # Copy binary and LICENSE
    cp "zig-out/bin/${binary_name}" "${staging_dir}/"
    cp LICENSE "${staging_dir}/"

    # Create archive
    pushd dist > /dev/null
    if [[ "${target}" == *"windows"* ]]; then
        zip -r "${archive_name}" "toss-${VERSION}-${target}"
    else
        tar -czvf "${archive_name}" "toss-${VERSION}-${target}"
    fi
    popd > /dev/null

    # Clean up staging directory
    rm -rf "${staging_dir}"

    # Show binary size
    echo "  Binary size: $(ls -lh "zig-out/bin/${binary_name}" | awk '{print $5}')"
    echo ""
done

# Clean up final zig-out
rm -rf zig-out

echo "=== Release build complete! ==="
echo ""
echo "Release archives in dist/:"
ls -lh dist/
echo ""
echo "Checksums:"
cd dist && shasum -a 256 * && cd ..
