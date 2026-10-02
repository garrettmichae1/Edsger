#!/usr/bin/env bash
set -euo pipefail

if ! command -v cmake >/dev/null; then
    echo 'CMake 3.28 or later is required to build the llama.cpp simulator slice.' >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/vendor/llama/source-b11306"
FRAMEWORK_DIR="$ROOT_DIR/vendor/llama/build-apple"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    git clone --depth 1 --branch b11306 https://github.com/ggml-org/llama.cpp.git "$SOURCE_DIR"
fi

(cd "$SOURCE_DIR" && ./build-xcframework.sh ios-sim)

rm -rf "$FRAMEWORK_DIR/llama-combined.xcframework"
xcodebuild -create-xcframework \
    -framework "$FRAMEWORK_DIR/llama.xcframework/ios-arm64/llama.framework" \
    -framework "$SOURCE_DIR/build-apple/llama.xcframework/ios-arm64_x86_64-simulator/llama.framework" \
    -output "$FRAMEWORK_DIR/llama-combined.xcframework"
rm -rf "$FRAMEWORK_DIR/llama.xcframework"
mv "$FRAMEWORK_DIR/llama-combined.xcframework" "$FRAMEWORK_DIR/llama.xcframework"
