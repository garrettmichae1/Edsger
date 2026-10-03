import Foundation

enum ChatModel: String, CaseIterable, Identifiable, Sendable {
    case standard, mini
    var id: String { rawValue }
    var title: String { self == .mini ? "Edsger Mini 1.0" : "Edsger 1.0" }

    /// Keep Qwen's established template unchanged. Liquid requires BOS and no thinking prefix.
    func adaptPrompt(_ qwenPrompt: String) -> String {
        guard self == .mini else { return qwenPrompt }
        let suffix = "<think>\n</think>\n"
        let text = qwenPrompt.hasSuffix(suffix) ? String(qwenPrompt.dropLast(suffix.count)) : qwenPrompt
        return "<|startoftext|>" + text
    }
}

enum MiniModelAsset {
    // Immutable upstream artifact, never a moving `main` download or arbitrary model URL.
    static let revision = "8ed288026e23958ad9dfa92d53ed773a8eee7125"
    static let filename = "LFM2.5-1.2B-Instruct-Q4_K_M.gguf"
    static let byteCount: Int64 = 730_895_168
    static let sha256 = "b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5"
    static func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: filename, withExtension: nil)
    }
    // Only the exact download from the previous release is eligible for cleanup.
    static var legacyDownloadURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lilC/OptionalModels", isDirectory: true)
            .appendingPathComponent(filename)
    }
}

enum ChatModelError: LocalizedError {
    case busy, missing, invalidAsset
    var errorDescription: String? {
        switch self {
        case .busy: "Wait for the current response or model change to finish."
        case .missing: "Edsger Mini is missing from this app installation."
        case .invalidAsset: "Edsger Mini could not be verified. Reinstall the app to restore its model."
        }
    }
}

protocol ChatModelActivating: Sendable {
    func activateChatModel(_ model: ChatModel) async throws
    func unloadMiniModel() async
}

protocol ModelFileManaging: Sendable {
    func isInstalled() async -> Bool
    func verify() async throws
}
