#!/usr/bin/env bash
# Run the actual portable Swift routing tests without Xcode, iOS, or the model.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/Sources/MathCore" "$TEST_DIR/Tests/MathCoreTests"
cp "$ROOT_DIR"/lilC/Domain/{AgentModels,TutorModels,MathCalculation,MathPlanning}.swift "$TEST_DIR/Sources/MathCore/"
cp "$ROOT_DIR/lilCTests/MathEngineTests.swift" "$TEST_DIR/Tests/MathCoreTests/"
cat > "$TEST_DIR/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MathCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "MathCore"), .testTarget(name: "MathCoreTests", dependencies: ["MathCore"])
])
PACKAGE
swift test --package-path "$TEST_DIR" --scratch-path "$TEST_DIR/.build" --disable-sandbox
