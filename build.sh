#!/bin/bash
# Build script for zX12 shared library

set -e

echo "=== Building zX12 Library ==="
echo ""

#Make zig-out/bin if it doesn't exist
mkdir -p zig-out/bin

# Determine platform
OS=$(uname -s)
case "$OS" in
    Linux*)
        PLATFORM="linux"
        EXT="so"
        ;;
    Darwin*)
        PLATFORM="macos"
        EXT="dylib"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        PLATFORM="windows"
        EXT="dll"
        ;;
    *)
        echo "Unsupported platform: $OS"
        exit 1
        ;;
esac

echo "Platform: $PLATFORM"
echo "Building shared library: libzx12.$EXT"
echo ""

# Build shared library
zig build-lib src/main.zig \
    -dynamic \
    -lc \
    -femit-bin=./zig-out/bin/libzx12.$EXT \
    -O ReleaseFast

echo "✅ Build successful: libzx12.$EXT"
echo ""

# Build static library too
echo "Building static library: libzx12.a"
zig build-lib src/main.zig \
    -static \
    -lc \
    -femit-bin=./zig-out/bin/libzx12.a \
    -O ReleaseFast

echo "✅ Build successful: libzx12.a"
echo ""

# Build C example if --build-c-example
if [ "$1" == "--build-c-example" ]; then
    if [ -f examples/c/example.c ]; then
        echo "Building C example..."
        gcc -o zx12_example \
            examples/c/example.c \
            -L. -lzx12 \
            -I./include \
            -Wl,-rpath,. \
            -O2

        echo "✅ C example built: ./zx12_example"
        echo ""
    fi
fi

echo "=== Build Complete ==="
echo ""
echo "Usage:"
echo "  C example:    ./zx12_example samples/837p_example.x12 schema/837p.json"
echo "  Python:       python3 examples/python/zx12_example.py samples/837p_example.x12 schema/837p.json"
echo ""
echo "Library files:"
echo "  - libzx12.$EXT (shared library)"
echo "  - libzx12.a (static library)"
echo "  - zx12_example (C example executable)"
