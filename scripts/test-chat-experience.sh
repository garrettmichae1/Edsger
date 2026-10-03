#!/usr/bin/env bash
# Test the production session, persistence, scrolling policy, and calculator routing.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -O \
  "$ROOT_DIR/lilC/Domain/AgentModels.swift" \
  "$ROOT_DIR/lilC/Domain/TutorModels.swift" \
  "$ROOT_DIR/lilC/Domain/DocumentText.swift" \
  "$ROOT_DIR/lilC/Domain/MathCalculation.swift" \
  "$ROOT_DIR/lilC/Domain/MathPlanning.swift" \
  "$ROOT_DIR/lilC/Application/TutorSession.swift" \
  "$ROOT_DIR/scripts/chat-experience-tests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
