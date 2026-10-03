#!/usr/bin/env bash
# Production parsers, ZIP extraction, retrieval, routing and persistence; no model/Apple SDK required.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/Sources/DocumentTests"
for file in Domain/AgentModels.swift Domain/TutorModels.swift Domain/DocumentText.swift Domain/DocumentTutorClient.swift Infrastructure/ChatDocumentStore.swift Application/TutorSession.swift; do
  cp "$ROOT_DIR/lilC/$file" "$TEST_DIR/Sources/DocumentTests/"
done
cp "$ROOT_DIR/scripts/chat-document-tests.swift" "$TEST_DIR/Sources/DocumentTests/Tests.swift"
python3 - "$TEST_DIR" <<'PY'
import json, os, sys
from pathlib import Path
root = Path(sys.argv[1])
local = os.environ.get('EDSGER_ZIPFOUNDATION_PATH')
dep = '.package(path: ' + json.dumps(local) + ')' if local else '.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")'
identity = Path(local).name if local else 'ZIPFoundation'
(root/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DocumentTests", dependencies: [''' + dep + '''], targets: [
 .executableTarget(name: "DocumentTests", dependencies: [.product(name: "ZIPFoundation", package: '''+json.dumps(identity)+''')])
])
''')
PY
swift run --package-path "$TEST_DIR" -c release DocumentTests
