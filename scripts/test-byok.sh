#!/usr/bin/env bash
# Compile actual provider transport, keychain and settings state on macOS.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/Sources/BYOKCore" "$TEST_DIR/Tests/BYOKCoreTests"
cp "$ROOT_DIR"/lilC/Domain/{BYOKModels,AgentModels,TutorModels,MathCalculation,MathPlanning,MobileAgent}.swift "$TEST_DIR/Sources/BYOKCore/"
cp "$ROOT_DIR"/lilC/Infrastructure/{BYOKClient,ProviderKeychain,MobileAgentClient}.swift "$TEST_DIR/Sources/BYOKCore/"
cp "$ROOT_DIR/lilC/Application/BYOKStore.swift" "$TEST_DIR/Sources/BYOKCore/"
# This enum bridges only the unrelated IDE workspace dependency for host tests.
cat > "$TEST_DIR/Sources/BYOKCore/HostLanguage.swift" <<'SWIFT'
enum ProgrammingLanguage: String { case c, python, javascript, lua }
SWIFT
cp "$ROOT_DIR/lilCTests/BYOKTests.swift" "$TEST_DIR/Tests/BYOKCoreTests/"
cat > "$TEST_DIR/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BYOKCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "BYOKCore"), .testTarget(name: "BYOKCoreTests", dependencies: ["BYOKCore"])
])
PACKAGE
swift test --package-path "$TEST_DIR" --disable-sandbox "$@"
