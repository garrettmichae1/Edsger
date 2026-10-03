import Foundation
import Observation

@Observable @MainActor
final class ChatModelStore {
    private(set) var selected: ChatModel
    private(set) var miniAvailable = false
    private(set) var isChanging = false
    private(set) var activeReplies = 0
    private(set) var errorMessage: String?
    var canChange: Bool { !isChanging && activeReplies == 0 }
    private let defaults: UserDefaults
    private let files: any ModelFileManaging
    private let runtime: any ChatModelActivating
    static let preferenceKey = "edsger.chat.model"

    init(defaults: UserDefaults = .standard, files: any ModelFileManaging, runtime: any ChatModelActivating) {
        self.defaults = defaults; self.files = files; self.runtime = runtime
        selected = ChatModel(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .standard
    }

    func refresh() async {
        miniAvailable = await files.isInstalled()
        if !miniAvailable && selected == .mini && canChange { setSelection(.standard) }
    }

    func select(_ model: ChatModel) async {
        guard canChange else { return }
        isChanging = true; errorMessage = nil
        defer { isChanging = false }
        do {
            if model == .mini { try await files.verify() }
            try await runtime.activateChatModel(model)
            setSelection(model)
        } catch {
            // The old context may already have been released. Standard can always load lazily.
            setSelection(.standard)
            await runtime.unloadMiniModel()
            errorMessage = "Using Edsger 1.0. " + error.localizedDescription
        }
    }

    /// Pin one choice across planning, calculation, and explanation. UI cannot switch mid-turn.
    func beginReply() async throws -> ChatModel {
        guard !isChanging else { throw ChatModelError.busy }
        activeReplies += 1
        do {
            if selected == .mini { try await files.verify() }
            try Task.checkCancellation()
            return selected
        } catch {
            activeReplies -= 1
            if error is CancellationError { throw error }
            setSelection(.standard)
            errorMessage = "Mini is unavailable. Using Edsger 1.0. " + error.localizedDescription
            activeReplies += 1
            return .standard
        }
    }
    func endReply() { activeReplies = max(0, activeReplies - 1) }
    func clearError() { errorMessage = nil }
    private func setSelection(_ model: ChatModel) {
        selected = model; defaults.set(model.rawValue, forKey: Self.preferenceKey)
    }
}
