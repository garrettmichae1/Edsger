#!/usr/bin/env bash
# macOS host smoke, real models. iPhone performance still requires a device build.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MINI_MODEL="${1:?Pass the downloaded LFM2.5-1.2B-Instruct-Q4_K_M.gguf path}"
STANDARD_MODEL="${2:-$ROOT_DIR/lilC/Resources/Models/Qwen3.5-4B-Q4_K_M.gguf}"
echo 'b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5' " $MINI_MODEL" | shasum -a 256 --check
FRAMEWORK_DIR="$ROOT_DIR/vendor/llama/build-apple/llama-device-only.xcframework/macos-arm64_x86_64"
if [[ ! -d "$FRAMEWORK_DIR" ]]; then
  FRAMEWORK_DIR="$ROOT_DIR/vendor/llama/build-apple/llama.xcframework/macos-arm64_x86_64"
fi
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -O -F "$FRAMEWORK_DIR" -framework llama \
  -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" \
  "$ROOT_DIR/lilC/Domain/ChatModel.swift" \
  "$ROOT_DIR/lilC/Domain/AgentModels.swift" \
  "$ROOT_DIR/lilC/Domain/TutorModels.swift" \
  "$ROOT_DIR/lilC/Domain/MathCalculation.swift" \
  "$ROOT_DIR/lilC/Domain/MathPlanning.swift" \
  "$ROOT_DIR/lilC/Domain/MathMessage.swift" \
  "$ROOT_DIR/lilC/Infrastructure/PromptReuseCache.swift" \
  "$ROOT_DIR/lilC/Infrastructure/LocalAgentClient.swift" \
  "$ROOT_DIR/scripts/mini-model-smoke.swift" -o "$TEST_DIR/smoke"
"$TEST_DIR/smoke" "$MINI_MODEL" "$STANDARD_MODEL"
