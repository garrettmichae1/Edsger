#!/usr/bin/env bash
# Compile shared inference code against Apple's real OSLog, without loading a model.
# This is a macOS compile check, not a substitute for building the iOS app in Xcode.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This check requires macOS and Apple's SDK (real OSLog)." >&2
  exit 1
fi
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORK_DIR="$ROOT_DIR/vendor/llama/build-apple/llama-device-only.xcframework/macos-arm64_x86_64"
if [[ ! -d "$FRAMEWORK_DIR" ]]; then
  FRAMEWORK_DIR="$ROOT_DIR/vendor/llama/build-apple/llama.xcframework/macos-arm64_x86_64"
fi
if [[ ! -d "$FRAMEWORK_DIR" ]]; then
  echo "Missing macOS llama framework; run scripts/fetch-agent-assets.sh first." >&2
  exit 1
fi
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -O -whole-module-optimization -c -F "$FRAMEWORK_DIR" \
  "$ROOT_DIR/lilC/Domain/AgentModels.swift" \
  "$ROOT_DIR/lilC/Domain/TutorModels.swift" \
  "$ROOT_DIR/lilC/Domain/MathCalculation.swift" \
  "$ROOT_DIR/lilC/Domain/MathPlanning.swift" \
  "$ROOT_DIR/lilC/Infrastructure/PromptReuseCache.swift" \
  "$ROOT_DIR/lilC/Infrastructure/LocalAgentClient.swift" \
  -o "$TEST_DIR/inference.o"
echo "Shared inference code compiled with Apple's OSLog. The iOS app build remains a separate check."
