#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="$ROOT_DIR/lilC/Resources/Models"
MODEL_FILE="$MODEL_DIR/LFM2.5-1.2B-Instruct-Q4_K_M.gguf"
MODEL_SHA="b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5"
MODEL_URL="https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/8ed288026e23958ad9dfa92d53ed773a8eee7125/LFM2.5-1.2B-Instruct-Q4_K_M.gguf"

mkdir -p "$MODEL_DIR"
if [[ ! -f "$MODEL_FILE" ]]; then
    TEMP_FILE="$(mktemp "$MODEL_DIR/.mini-download.XXXXXX")"
    trap 'rm -f "$TEMP_FILE"' EXIT
    curl --fail --location --retry 3 --output "$TEMP_FILE" "$MODEL_URL"
    echo "$MODEL_SHA  $TEMP_FILE" | shasum -a 256 --check
    mv "$TEMP_FILE" "$MODEL_FILE"
fi
echo "$MODEL_SHA  $MODEL_FILE" | shasum -a 256 --check
