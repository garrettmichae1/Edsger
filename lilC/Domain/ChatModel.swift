import Foundation

enum ChatModel: String, CaseIterable, Identifiable, Sendable {
    case standard, mini
    var id: String { rawValue }
    var title: String { self == .mini ? "Edsger mini" : "Edsger" }
    var subtitle: String {
        self == .mini ? "A lighter model for everyday chat. Experimental." : "The original model for deeper answers."
    }

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
    static let downloadURL = URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/\(revision)/\(filename)")!
    static let licenseURL = URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/blob/\(revision)/LICENSE")!
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lilC/OptionalModels", isDirectory: true)
    }
    static var installedURL: URL { directory.appendingPathComponent(filename) }
}

enum ChatModelError: LocalizedError {
    case busy, missing, invalidDownload, insufficientSpace
    var errorDescription: String? {
        switch self {
        case .busy: "Wait for the current response or model change to finish."
        case .missing: "Download Edsger mini before selecting it."
        case .invalidDownload: "The Mini download could not be verified. Delete it and download it again."
        case .insufficientSpace: "Free at least 1.5 GB of storage before downloading Edsger mini."
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
    func download(onProgress: @escaping @Sendable (Double) -> Void) async throws
    func remove() async throws
}
