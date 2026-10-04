#!/usr/bin/env bash
# Render the actual MembershipScreen in an isolated simulator-only preview app.
# Commerce fixtures never enter the Edsger target; no keys or network calls.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${1:-/tmp/edsger-pro-previews}"
PREVIEW_DIR="$(mktemp -d)"
trap 'rm -rf "$PREVIEW_DIR"' EXIT
mkdir -p "$OUTPUT_DIR" "$PREVIEW_DIR/MembershipPreview.app"
python3 - "$ROOT_DIR" "$PREVIEW_DIR" <<'PY'
from pathlib import Path
import sys
root, dest = map(Path, sys.argv[1:])
screen = (root / 'lilC/Presentation/MembershipScreen.swift').read_text()
# Previews macros are Xcode canvas entry points, not standalone app content.
screen = '\n'.join(line for line in screen.splitlines() if not line.startswith('#Preview'))
(dest / 'MembershipScreen.swift').write_text(screen)
# The isolated visual fixture shows a launch-ready CTA. Production remains off.
domain = (root / 'lilC/Domain/MobileAgent.swift').read_text().replace('static let isEnabled = false', 'static let isEnabled = true')
(dest / 'MobileAgent.swift').write_text(domain)
PY
cat > "$PREVIEW_DIR/PreviewFixture.swift" <<'SWIFT'
import Foundation
import Observation
import SwiftUI
import UIKit

protocol TutorRequestFailure: Error {}
struct PreviewProduct { let displayPrice: String }
@Observable @MainActor final class AgentSettingsStore {
    static let shared = AgentSettingsStore()
    var products = [EdsgerMembership.pro.rawValue: PreviewProduct(displayPrice: "$10.00"), EdsgerMembership.plus.rawValue: PreviewProduct(displayPrice: "$25.00")]
    var membership: EdsgerMembership? = ProcessInfo.processInfo.arguments.contains("--member") ? .pro : nil
    var isSubscribed: Bool { membership != nil }
    var isPurchasing = false
    var sharingConsent = false
    var storeMessage: String?
    init(defaults: UserDefaults = .standard) {}
    func loadStore() async {}
    func purchase(_ plan: EdsgerMembership) async { storeMessage = "Visual fixture only. No purchase was made." }
    func restore() async {}
}
@Observable @MainActor final class MobileAgentStore {
    static let shared = MobileAgentStore()
    var allowance: MobileAgentAllowance? = .init(remainingNanoUSD: "4000000000", limitNanoUSD: "5000000000", renewsAt: Int64(Date().addingTimeInterval(20 * 86_400).timeIntervalSince1970 * 1000), available: true, rateCard: "visual-fixture")
    var notice: String?
    func refresh() async {}
}
enum AppHaptics { static func tap() {} }
enum LegalURLs {
    static let privacy = URL(string: "https://example.invalid/privacy")!
    static let terms = URL(string: "https://example.invalid/terms")!
}

/// Scroll the native hierarchy for screenshots without altering the sales view.
struct PreviewScroll: UIViewRepresentable {
    let offset: CGFloat
    func makeUIView(context: Context) -> UIView {
        let marker = UIView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            func find(_ view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView { return scroll }
                for child in view.subviews { if let result = find(child) { return result } }
                return nil
            }
            guard let root = marker.window, let scroll = find(root) else { return }
            scroll.setContentOffset(CGPoint(x: 0, y: min(offset, max(0, scroll.contentSize.height - scroll.bounds.height))), animated: false)
        }
        return marker
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

@main struct MembershipPreviewApp: App {
    private let arguments = ProcessInfo.processInfo.arguments
    var body: some Scene {
        WindowGroup {
            MembershipScreen(settings: .shared) {}
                .preferredColorScheme(arguments.contains("--dark") ? .dark : .light)
                .environment(\.dynamicTypeSize, arguments.contains("--large") ? .accessibility3 : .large)
                .overlay {
                    if arguments.contains("--plans") { PreviewScroll(offset: 700).allowsHitTesting(false) }
                }
        }
    }
}
SWIFT
cat > "$PREVIEW_DIR/MembershipPreview.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.edsger.membership-visual-preview</string>
<key>CFBundleExecutable</key><string>MembershipPreview</string>
<key>CFBundleName</key><string>Pro Preview</string>
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
xcrun swiftc -sdk "$SDK_PATH" -target "$PREVIEW_ARCH-apple-ios17.0-simulator" -parse-as-library -module-name MembershipPreview \
    "$PREVIEW_DIR/MobileAgent.swift" "$PREVIEW_DIR/MembershipScreen.swift" "$PREVIEW_DIR/PreviewFixture.swift" \
    -o "$PREVIEW_DIR/MembershipPreview.app/MembershipPreview"
codesign --force --sign - "$PREVIEW_DIR/MembershipPreview.app"
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
xcrun simctl install "$DEVICE_ID" "$PREVIEW_DIR/MembershipPreview.app"
for STATE in light dark large-text plans-light plans-dark member; do
    set --
    case "$STATE" in
        dark) set -- --dark ;;
        large-text) set -- --large ;;
        plans-light) set -- --plans ;;
        plans-dark) set -- --plans --dark ;;
        member) set -- --member ;;
    esac
    xcrun simctl terminate "$DEVICE_ID" app.edsger.membership-visual-preview >/dev/null 2>&1 || true
    xcrun simctl launch "$DEVICE_ID" app.edsger.membership-visual-preview "$@"
    sleep 5
    xcrun simctl io "$DEVICE_ID" screenshot "$OUTPUT_DIR/$STATE.png"
done
printf 'Native membership previews saved to %s\n' "$OUTPUT_DIR"
