import Foundation
import Observation

@Observable @MainActor
final class ChatModelStore {
    private(set) var selected: ChatModel
    private(set) var miniInstalled = false
    private(set) var isChanging = false
    private(set) var isDownloading = false
    private(set) var downloadProgress = 0.0
    private(set) var activeReplies = 0
    private(set) var errorMessage: String?
    var canChange: Bool { !isChanging && activeReplies == 0 }
    private let defaults: UserDefaults
    private let files: any ModelFileManaging
    private let runtime: any ChatModelActivating
    private var downloadTask: Task<Void, Never>?
    private var downloadID = UUID()
    static let preferenceKey = "edsger.chat.model"

    init(defaults: UserDefaults = .standard, files: any ModelFileManaging, runtime: any ChatModelActivating) {
        self.defaults = defaults; self.files = files; self.runtime = runtime
        selected = ChatModel(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .standard
    }

    func refresh() async {
        miniInstalled = await files.isInstalled()
        if !miniInstalled && selected == .mini && canChange { setSelection(.standard) }
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
            errorMessage = "Using Edsger. " + error.localizedDescription
        }
    }

    func downloadMini() {
        guard !isDownloading, !miniInstalled, !isChanging else { return }
        isDownloading = true; downloadProgress = 0; errorMessage = nil
        downloadID = UUID()
        let id = downloadID
        downloadTask = Task {
            defer { isDownloading = false; downloadTask = nil }
            do {
                try await files.download { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isDownloading, self.downloadID == id else { return }
                        self.downloadProgress = progress
                    }
                }
                miniInstalled = true
            } catch {
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    func removeMini() async {
        guard canChange, !isDownloading else { return }
        isChanging = true; errorMessage = nil
        defer { isChanging = false }
        // Persist fallback before deleting, including if the app exits during this operation.
        setSelection(.standard)
        await runtime.unloadMiniModel()
        do { try await files.remove(); miniInstalled = false }
        catch { errorMessage = "Edsger is selected, but Mini could not be deleted. " + error.localizedDescription }
    }

    /// Pin one choice across planning, calculation, and explanation. UI cannot switch/delete mid-turn.
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
            errorMessage = "Mini is unavailable. Using Edsger. " + error.localizedDescription
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
