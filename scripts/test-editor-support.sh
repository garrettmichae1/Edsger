#!/usr/bin/env bash
# Production editor policies + production workspace + the actual app PicoC engine.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This host harness requires Linux. Run the lilC test scheme in Xcode on macOS." >&2
  exit 1
fi
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
PICOC="$ROOT_DIR/lilC/Vendor/PicoC"
python3 "$ROOT_DIR/scripts/editor-lua-fixtures.py" "$TEST_DIR"
clang -DLILC_IOS_HOST=1 -fPIC -shared -I "$PICOC" \
  "$PICOC"/lilc/lilc_picoc_runner.c "$PICOC"/lilc/platform_lilc_ios.c \
  "$PICOC"/{table,lex,parse,expression,heap,type,variable,clibrary,platform,include,debug}.c \
  "$PICOC"/cstdlib/*.c -pthread -lm -o "$TEST_DIR/libEditorPicoC.so"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -O \
  -import-objc-header "$PICOC/lilc/lilc_picoc_runner.h" \
  -L "$TEST_DIR" -lEditorPicoC -Xlinker -rpath -Xlinker "$TEST_DIR" \
  "$ROOT_DIR/lilC/Domain/EditorSupport.swift" \
  "$ROOT_DIR/lilC/Domain/ProgrammingLanguage.swift" \
  "$ROOT_DIR/lilC/Domain/CDiagnostics.swift" \
  "$ROOT_DIR/lilC/Domain/CIndentFormatter.swift" \
  "$ROOT_DIR/lilC/Domain/LocalCWorkspace.swift" \
  "$ROOT_DIR/lilC/Domain/FirstHourCurriculum.swift" \
  "$ROOT_DIR/lilC/Domain/LessonWin.swift" \
  "$ROOT_DIR/lilC/Domain/LessonProgress.swift" \
  "$ROOT_DIR/lilC/Domain/QuizProgress.swift" \
  "$ROOT_DIR/lilC/Domain/CQuiz.swift" \
  "$ROOT_DIR/lilC/Domain/LegalURLs.swift" \
  "$ROOT_DIR/lilC/Infrastructure/LocalScriptRunning.swift" \
  "$ROOT_DIR/scripts/editor-support-tests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/lua-fixtures.json"
