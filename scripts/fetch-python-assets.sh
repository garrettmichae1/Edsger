#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT_DIR/vendor/python"
ARCHIVE="$DEST/downloads/Python-3.14-iOS-support.b11.tar.gz"
SHA=b591f3301bd22a4f423c49c746cac9e55558b909fd14d6eb8327ccc62234ab7b
mkdir -p "$DEST/downloads"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 -o "$ARCHIVE.partial" 'https://github.com/beeware/Python-Apple-support/releases/download/3.14-b11/Python-3.14-iOS-support.b11.tar.gz'
    echo "$SHA  $ARCHIVE.partial" | shasum -a 256 --check
    mv "$ARCHIVE.partial" "$ARCHIVE"
fi
echo "$SHA  $ARCHIVE" | shasum -a 256 --check
mkdir -p "$DEST/3.14-b11"
tar -xzf "$ARCHIVE" -C "$DEST/3.14-b11"
echo 'CPython 3.14.7 device and simulator runtime ready.'
