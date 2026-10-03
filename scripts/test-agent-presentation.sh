#!/usr/bin/env bash
# Synchronous host checks for the production agent presentation and scroll policy.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -O \
  "$ROOT_DIR/lilC/Domain/AgentModels.swift" \
  "$ROOT_DIR/lilC/Domain/TutorModels.swift" \
  "$ROOT_DIR/scripts/agent-presentation-tests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
