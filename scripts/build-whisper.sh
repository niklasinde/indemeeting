#!/bin/bash
# Builds whisper.cpp from source into .deps/whisper.xcframework: one universal static library with Metal shaders
# embedded, so it links into the app binary and nothing has to be loaded (or signed) separately at runtime.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=v1.9.4
COMMIT=927cfce
DEPS="$PWD/.deps"
SRC="$DEPS/whisper.cpp"
BUILD="$DEPS/whisper-build"
OUT="$DEPS/whisper.xcframework"

command -v cmake >/dev/null || { echo "error: cmake is needed to build whisper.cpp (brew install cmake)"; exit 1; }

if [ ! -d "$SRC" ]; then
    mkdir -p "$DEPS"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/whisper.cpp "$SRC"
fi
[ "$(git -C "$SRC" rev-parse --short=7 HEAD)" = "$COMMIT" ] || { echo "error: $SRC is not whisper.cpp $TAG ($COMMIT)"; exit 1; }

cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF
cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.ncpu)"

SLICE=macos-arm64_x86_64
STAGE="$OUT/$SLICE"
rm -rf "$OUT"
mkdir -p "$STAGE/Headers"
libtool -static -no_warning_for_no_symbols -o "$STAGE/libwhisper.a" $(find "$BUILD/src" "$BUILD/ggml/src" -name '*.a')
GGML_HEADERS=(ggml.h ggml-alloc.h ggml-backend.h ggml-cpu.h ggml-metal.h ggml-blas.h gguf.h)
HEADERS=(whisper.h "${GGML_HEADERS[@]}")
cp "$SRC/include/whisper.h" "${GGML_HEADERS[@]/#/$SRC/ggml/include/}" "$STAGE/Headers/"
{
    echo "module whisper {"
    printf '    header "%s"\n' "${HEADERS[@]}"
    echo "    link \"c++\""
    printf '    link framework "%s"\n' Accelerate Foundation Metal MetalKit
    echo "    export *"
    echo "}"
} > "$STAGE/Headers/module.modulemap"
cat > "$OUT/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>HeadersPath</key><string>Headers</string>
            <key>LibraryIdentifier</key><string>$SLICE</string>
            <key>LibraryPath</key><string>libwhisper.a</string>
            <key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array>
            <key>SupportedPlatform</key><string>macos</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key><string>XFWK</string>
    <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
EOF
echo "Built $OUT"
