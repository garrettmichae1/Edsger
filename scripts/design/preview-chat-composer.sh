#!/usr/bin/env bash
# Render the actual EdsgerComposerBar in an isolated simulator-only preview app.
# Chat fixtures never enter the Edsger target; no keys or network calls.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${1:-/tmp/edsger-chat-previews}"
PREVIEW_DIR="$(mktemp -d)"
trap 'rm -rf "$PREVIEW_DIR"' EXIT
mkdir -p "$OUTPUT_DIR" "$PREVIEW_DIR/ComposerPreview.app"
python3 - "$ROOT_DIR" "$PREVIEW_DIR" <<'PYCODE'
from pathlib import Path
import sys
root, dest = map(Path, sys.argv[1:])
screen = (root / 'lilC/Presentation/EdsgerScreen.swift').read_text()
composer = screen[screen.index('/// A single row at rest;'):]
(dest / 'EdsgerComposerBar.swift').write_text('import SwiftUI\n' + composer)
PYCODE
cat > "$PREVIEW_DIR/PreviewFixture.swift" <<'SWIFT'
import SwiftUI

struct ChatPreview: View {
    private let arguments = ProcessInfo.processInfo.arguments
    @State private var draft = ProcessInfo.processInfo.arguments.contains("--multiline")
        ? "Create a Python program that reads a list of expenses, groups them by category, and prints a clear monthly summary. Include input validation and a few examples so I can try it in my project."
        : ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "line.3.horizontal").frame(width: 48, height: 48)
                Spacer()
                Text("Edsger 1.0").font(.headline)
                Image(systemName: "chevron.down")
                Spacer()
                Image(systemName: "square.and.pencil").frame(width: 48, height: 48)
            }
            .padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Spacer(); Text("Help me build a Python project.").padding(14).background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 24)) }
                    Text("EDSGER").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text("Let’s build something useful. What would you like your program to do?").font(.body)
                    Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    Text("Visual fixture · no model requests").font(.caption).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            EdsgerComposerBar(draft: $draft, focused: $focused,
                              isResponding: arguments.contains("--responding"),
                              canSend: !draft.isEmpty,
                              send: { draft = "" }, stop: {}) {
                Button("Files", systemImage: "paperclip") {}
                Button("Study Python") { draft = "Help me learn Python." }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(arguments.contains("--dark") ? Color(white: 0.055) : .white)
        .preferredColorScheme(arguments.contains("--dark") ? .dark : .light)
        .environment(\.dynamicTypeSize, arguments.contains("--large") ? .accessibility3 : .large)
        .task {
            if arguments.contains("--keyboard") { focused = true }
        }
    }
}
@main struct ComposerPreviewApp: App {
    var body: some Scene { WindowGroup { ChatPreview() } }
}
SWIFT
cat > "$PREVIEW_DIR/ComposerPreview.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.edsger.composer-visual-preview</string>
<key>CFBundleExecutable</key><string>ComposerPreview</string>
<key>CFBundleName</key><string>Chat Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PREVIEW_ARCH="$(uname -m)"
xcrun swiftc -sdk "$SDK_PATH" -target "$PREVIEW_ARCH-apple-ios17.0-simulator" -parse-as-library -module-name ComposerPreview \
    "$PREVIEW_DIR/EdsgerComposerBar.swift" "$PREVIEW_DIR/PreviewFixture.swift" \
    -o "$PREVIEW_DIR/ComposerPreview.app/ComposerPreview"
codesign --force --sign - "$PREVIEW_DIR/ComposerPreview.app"
xcrun simctl list devices available -j > "$PREVIEW_DIR/devices.json"
DEVICE_ID="$(python3 - "$PREVIEW_DIR/devices.json" <<'PY'
import json, sys
for devices in json.load(open(sys.argv[1]))['devices'].values():
    for device in devices:
        if device['name'].startswith('iPhone') and device.get('isAvailable'):
            print(device['udid']); sys.exit()
sys.exit('No available iPhone simulator')
PY
)"
xcrun simctl boot "$DEVICE_ID" || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl status_bar "$DEVICE_ID" override --time '9:41' --batteryState charged --batteryLevel 100
# Suppress the simulator’s first-use QuickPath introduction for the keyboard render.
xcrun simctl spawn "$DEVICE_ID" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
xcrun simctl install "$DEVICE_ID" "$PREVIEW_DIR/ComposerPreview.app"
for STATE in light dark multiline large-text responding keyboard; do
    set --
    case "$STATE" in
        dark) set -- --dark ;;
        large-text) set -- --large ;;
        multiline) set -- --multiline ;;
        responding) set -- --responding ;;
        keyboard) set -- --keyboard --multiline ;;
    esac
    xcrun simctl terminate "$DEVICE_ID" app.edsger.composer-visual-preview >/dev/null 2>&1 || true
    xcrun simctl launch "$DEVICE_ID" app.edsger.composer-visual-preview "$@"
    sleep 5
    xcrun simctl io "$DEVICE_ID" screenshot "$OUTPUT_DIR/$STATE.png"
done
printf 'Native chat previews saved to %s\n' "$OUTPUT_DIR"
