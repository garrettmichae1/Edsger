import Foundation
import Observation

enum OnboardingCopy {
    struct Feature: Identifiable, Sendable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    struct Page: Identifiable, Sendable {
        let id: String
        let label: String
        let artwork: String
        let headline: String
        let detail: String
        let features: [Feature]
        let footnote: String
    }

    static let pages: [Page] = [
        Page(
            id: "privacy", label: "ON YOUR DEVICE",
            artwork: """
                .---------------.
                |    .-----.    |
                |    |  *  |    |
                |    '-----'    |
                |               |
                |  your AI      |
                |  right here_  |
                '---------------'
            """,
            headline: "Your AI.\nYour device.",
            detail: "Chat, learn, and build with AI that runs entirely on your iPhone or iPad.",
            features: [
                Feature(symbol: "lock", title: "Private by design", detail: "Chat and Agent don't send prompts or code to cloud AI."),
                Feature(symbol: "wifi.slash", title: "Ready offline", detail: "The AI model is included with the app.")
            ],
            footnote: "Local replies need no cloud AI data-center compute. Sharing and device backups follow your iOS settings."
        ),
        Page(
            id: "chat", label: "ASK. EXPLORE. UNDERSTAND.",
            artwork: """
                > what if ... ?

                  .-----------.
                  | let's     |
                  | work it   |
                  | out_      |
                  '--------+--'
                           '
            """,
            headline: "Follow your curiosity.",
            detail: "Ask about math, code, science, or a new idea. Keep the conversation going at your own pace.",
            features: [
                Feature(symbol: "function", title: "Math, worked out", detail: "A local math engine supports calculations in Chat."),
                Feature(symbol: "pin", title: "Pick up where you left off", detail: "Saved chats, pinned favorites, and unfinished drafts.")
            ],
            footnote: "AI can make mistakes. Check important answers."
        ),
        Page(
            id: "ide", label: "A POCKET IDE",
            artwork: """
                +-----------------+
                | hello.py    RUN |
                +-----------------+
                | 1 print('hello')|
                +-----------------+
                | > hello         |
                +-----------------+
            """,
            headline: "Make something real.",
            detail: "Write and run supported C, Python, JavaScript, and Lua programs on your iPhone or iPad.",
            features: [
                Feature(symbol: "curlybraces", title: "An editor that helps", detail: "Syntax highlighting, line numbers, and runtime error markers."),
                Feature(symbol: "folder", title: "Room for your projects", detail: "Organize files, run code, and inspect the output.")
            ],
            footnote: "Available libraries and runtime features vary by language."
        ),
        Page(
            id: "agent", label: "BUILD WITH EDSGER",
            artwork: """
                [ your idea ]
                      |
                      v
                [ edit + run ]
                      |
                      v
                [ review ] <--+
                      |       |
                      +-- undo+
            """,
            headline: "Help with the work.\nYou keep control.",
            detail: "Open Agent in the IDE's output area. Ask Edsger to read files, make changes, or help fix errors.",
            features: [
                Feature(symbol: "arrow.uturn.backward", title: "Change your mind", detail: "Restore a saved project checkpoint to roll back agent changes."),
                Feature(symbol: "bubble.left.and.bubble.right", title: "Keep ideas separate", detail: "Start a new agent chat or return to project conversation history.")
            ],
            footnote: "Review edits and run output before relying on the result."
        )
    ]

    static var pageCount: Int { pages.count }
    static let continueTitle = "Continue"
    static let getStartedTitle = "Get started"
    static let skipTitle = "Skip"

    static let filesFolderTip = "Create a folder, then drag C files into it."
}

@MainActor
@Observable
final class OnboardingStore {
    static let shared = OnboardingStore()
    static let storageKey = "lilc.onboarding.completed"
    static let filesFolderTipKey = "lilc.files.folderDragTip.seen"

    private let defaults: UserDefaults

    var hasCompleted: Bool {
        didSet { defaults.set(hasCompleted, forKey: Self.storageKey) }
    }

    var hasSeenFilesFolderTip: Bool {
        didSet { defaults.set(hasSeenFilesFolderTip, forKey: Self.filesFolderTipKey) }
    }

    var needsOnboarding: Bool {
        if Self.screenshotsBypassOnboarding { return false }
        return !hasCompleted
    }

    var needsFilesFolderTip: Bool {
        if Self.screenshotsBypassOnboarding { return false }
        return !hasSeenFilesFolderTip
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompleted = defaults.bool(forKey: Self.storageKey)
        hasSeenFilesFolderTip = defaults.bool(forKey: Self.filesFolderTipKey)
    }

    func complete() {
        hasCompleted = true
    }

    func dismissFilesFolderTip() {
        hasSeenFilesFolderTip = true
    }

    private static var screenshotsBypassOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_STORE_SHOTS")
    }
}
