#!/bin/bash
# Builds llama.cpp and whisper.cpp from source against one shared ggml into .deps/ggml.xcframework: one universal static
# library with Metal shaders embedded, so it links into the app binary and nothing has to be loaded (or signed) separately.
set -euo pipefail
cd "$(dirname "$0")/.."

WHISPER_TAG=v1.9.4
WHISPER_COMMIT=927cfce
LLAMA_TAG=b10901
LLAMA_COMMIT=28ff095
DEPS="$PWD/.deps"
BUILD="$DEPS/ggml-build"
OUT="$DEPS/ggml.xcframework"

command -v cmake >/dev/null || { echo "error: cmake is needed to build whisper.cpp and llama.cpp (brew install cmake)"; exit 1; }

fetch() {
    local repo=$1 tag=$2 commit=$3 dir=$4
    [ -d "$dir" ] || git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "https://github.com/ggml-org/$repo" "$dir"
    [ "$(git -C "$dir" rev-parse --short=7 HEAD)" = "$commit" ] || { echo "error: $dir is not $repo $tag ($commit)"; exit 1; }
}
fetch whisper.cpp "$WHISPER_TAG" "$WHISPER_COMMIT" "$DEPS/whisper.cpp"
fetch llama.cpp "$LLAMA_TAG" "$LLAMA_COMMIT" "$DEPS/llama.cpp"

cmake -S scripts/ggml -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_SOURCE="$DEPS/llama.cpp" -DWHISPER_SOURCE="$DEPS/whisper.cpp" \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON \
    -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_OPENSSL=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF
cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.ncpu)" --target llama whisper

SLICE=macos-arm64_x86_64
STAGE="$OUT/$SLICE"
rm -rf "$OUT"
mkdir -p "$STAGE/Headers"
libtool -static -no_warning_for_no_symbols -o "$STAGE/libggml.a" $(find "$BUILD" -name '*.a')
GGML_HEADERS=(ggml.h ggml-alloc.h ggml-backend.h ggml-cpu.h ggml-metal.h ggml-blas.h ggml-opt.h gguf.h)
HEADERS=(whisper.h llama.h "${GGML_HEADERS[@]}")
cp "$DEPS/whisper.cpp/include/whisper.h" "$DEPS/llama.cpp/include/llama.h" "${GGML_HEADERS[@]/#/$DEPS/llama.cpp/ggml/include/}" \
    "$STAGE/Headers/"
{
    echo "module ggml {"
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
            <key>LibraryPath</key><string>libggml.a</string>
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
