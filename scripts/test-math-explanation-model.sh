#!/usr/bin/env bash
# macOS real-model smoke. Python must have pinned SymPy 1.14.0 / mpmath 1.3.0.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MINI_MODEL="${1:?Pass the Mini GGUF path}"
STANDARD_MODEL="${2:?Pass the Standard GGUF path}"
PYTHON_BIN="${3:?Pass the host Python executable with SymPy installed}"
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
  "$ROOT_DIR/lilC/Infrastructure/PromptReuseCache.swift" \
  "$ROOT_DIR/lilC/Infrastructure/LocalAgentClient.swift" \
  "$ROOT_DIR/scripts/math-explanation-model-smoke.swift" -o "$TEST_DIR/smoke"
"$TEST_DIR/smoke" "$MINI_MODEL" "$STANDARD_MODEL" "$PYTHON_BIN" "$ROOT_DIR/lilC/Infrastructure/math_bootstrap.py"
