#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library -O \
  "$ROOT_DIR/lilC/Infrastructure/PromptReuseCache.swift" \
  "$ROOT_DIR/scripts/prompt-cache-tests.swift" -o "$TEST_DIR/cache-tests"
"$TEST_DIR/cache-tests"
