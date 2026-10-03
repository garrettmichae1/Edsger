import Foundation
import Observation

enum OnboardingCopy {
    static let headline = "Local AI.\nA developer who gives a shit."
    static let introduction = "I care about the environment. I’m tired of cloud AI and the shitty CEOs behind it. So I’m building something I actually believe in."
    static let localTitle = "Your device does the work."
    static let localBody = "Chat and Agent run on your iPhone or iPad. No cloud AI requests. No AI account or API key. Your prompts and code stay out of cloud AI services."
    static let featuresTitle = "Ask. Code. Build."
    static let featuresBody = "Ask questions and work through math. Write and run C, Python, JavaScript, or Lua. Get help from the IDE agent, and roll back its changes when you need to."
    static let commitmentTitle = "I’m here to make it better."
    static let commitmentBody = "I care about this app and the people using it. I’ll keep fixing bugs, listening to feedback, and making local AI as good as I can."
    static let footnote = "Local AI still uses power. Sharing and device backups follow your iOS settings."
    static let getStartedTitle = "Let’s go"
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
