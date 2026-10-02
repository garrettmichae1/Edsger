#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="$ROOT_DIR/lilC/Resources/Models"
FRAMEWORK_DIR="$ROOT_DIR/vendor/llama"
MODEL_FILE="$MODEL_DIR/Qwen3.5-4B-Q4_K_M.gguf"
FRAMEWORK_ZIP="$FRAMEWORK_DIR/llama-b11306-xcframework.zip"

mkdir -p "$MODEL_DIR" "$FRAMEWORK_DIR"

if [[ ! -f "$MODEL_FILE" ]]; then
    curl --fail --location --retry 3 --output "$MODEL_FILE" \
        'https://huggingface.co/Canfield/Qwen3.5-4B-Q4_K_M-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf'
fi
echo '25082a7dd3776cc3c741c6347d3bd04523f05796607b3fbc32fa3a25dfa1418c' " $MODEL_FILE" | shasum -a 256 --check

if [[ ! -f "$FRAMEWORK_ZIP" ]]; then
    curl --fail --location --retry 3 --output "$FRAMEWORK_ZIP" \
        'https://github.com/ggml-org/llama.cpp/releases/download/b11306/llama-b11306-xcframework.zip'
fi
echo '5de33d22bd00e3492196c2fc9893f34164ae99307c3d5f20c81c879b8fd93c51' " $FRAMEWORK_ZIP" | shasum -a 256 --check

if [[ ! -d "$FRAMEWORK_DIR/build-apple/llama.xcframework" ]]; then
    unzip -q "$FRAMEWORK_ZIP" -d "$FRAMEWORK_DIR"
fi
