#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORK_DIR="$ROOT_DIR/vendor/llama/build-apple/llama-device-only.xcframework/macos-arm64_x86_64"
if [[ ! -d "$FRAMEWORK_DIR" ]]; then
  FRAMEWORK_DIR="$ROOT_DIR/vendor/llama/build-apple/llama.xcframework/macos-arm64_x86_64"
fi
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library -O -F "$FRAMEWORK_DIR" -framework llama \
  -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" \
  "$ROOT_DIR/lilC/Domain/AgentModels.swift" \
  "$ROOT_DIR/lilC/Domain/TutorModels.swift" \
  "$ROOT_DIR/lilC/Domain/MathCalculation.swift" \
  "$ROOT_DIR/lilC/Domain/MathPlanning.swift" \
  "$ROOT_DIR/lilC/Infrastructure/PromptReuseCache.swift" \
  "$ROOT_DIR/lilC/Infrastructure/LocalAgentClient.swift" \
  "$ROOT_DIR/scripts/sampler-smoke.swift" -o "$TEST_DIR/smoke"
"$TEST_DIR/smoke" "$ROOT_DIR/lilC/Resources/Models/Qwen3.5-4B-Q4_K_M.gguf"
