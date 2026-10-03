#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Compile the unchanged production language/file value types without linking the
# workspace's native interpreters, which are unrelated to layout persistence.
python3 - "$ROOT_DIR" "$TEST_DIR" <<'PY_TYPES'
from pathlib import Path
import sys
root, target = map(Path, sys.argv[1:])
language = (root / 'lilC/Domain/ProgrammingLanguage.swift').read_text().split('\nenum PythonDiagnostics {', 1)[0]
file_type = (root / 'lilC/Domain/LocalCWorkspace.swift').read_text().split('\nstruct LocalCFolder:', 1)[0]
(target / 'ProgrammingLanguage.swift').write_text(language)
(target / 'LocalCFile.swift').write_text(file_type)
PY_TYPES
swiftc -module-cache-path "$TEST_DIR/cache" -swift-version 6 -strict-concurrency=complete -parse-as-library \
    "$TEST_DIR/ProgrammingLanguage.swift" \
    "$TEST_DIR/LocalCFile.swift" \
    "$ROOT_DIR/lilC/Domain/IDEHomeLayout.swift" \
    "$ROOT_DIR/scripts/ide-home-layout-tests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
