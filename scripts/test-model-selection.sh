#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/cache" -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT_DIR/lilC/Domain/ChatModel.swift" \
  "$ROOT_DIR/lilC/Domain/AgentModels.swift" \
  "$ROOT_DIR/lilC/Domain/TutorModels.swift" \
  "$ROOT_DIR/lilC/Domain/MathCalculation.swift" \
  "$ROOT_DIR/lilC/Domain/MathPlanning.swift" \
  "$ROOT_DIR/lilC/Application/ChatModelStore.swift" \
  "$ROOT_DIR/scripts/model-selection-tests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
