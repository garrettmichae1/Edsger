import Foundation
import Observation

@Observable
@MainActor
final class TutorSession {
    private(set) var conversations: [TutorConversation]
    private(set) var selectedID: UUID
    var draft: String {
        get { draft(for: selectedID) }
        set {
            guard newValue != draft else { return }
            drafts[selectedID.uuidString] = newValue.isEmpty ? nil : newValue
            draftStateDirty = true
            scheduleDraftSave()
        }
    }
    private(set) var isResponding = false
    private(set) var generationStatus: GenerationStatus?
    private(set) var transcriptRevision = 0
    private(set) var errorMessage: String?
    private(set) var notice: String?
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private let client: any TutorCompleting
    private let storageURL: URL
    private let draftsURL: URL
    private var drafts: [String: String]
    private var draftStateDirty = false
    private var draftSaveTask: Task<Void, Never>?

    private struct DraftState: Codable {
        var selectedID: UUID
        var drafts: [String: String]
    }

    func draft(for id: UUID) -> String { drafts[id.uuidString] ?? "" }

    var current: TutorConversation { conversations.first { $0.id == selectedID } ?? conversations[0] }
    var messages: [TutorMessage] { current.messages }

    init(client: any TutorCompleting = CalculatingTutorClient.shared, storageURL: URL? = nil) {
        self.client = client
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageURL = storageURL ?? support.appendingPathComponent("lilC/edsger-conversations.json")
        self.draftsURL = self.storageURL.deletingPathExtension().appendingPathExtension("drafts.json")
        let loaded = (try? Data(contentsOf: self.storageURL)).flatMap { try? JSONDecoder().decode([TutorConversation].self, from: $0) } ?? []
        let savedDrafts = (try? Data(contentsOf: self.draftsURL)).flatMap { try? JSONDecoder().decode(DraftState.self, from: $0) }
        let initial = loaded.isEmpty ? [TutorConversation()] : loaded.sorted(by: TutorConversation.historyOrder)
        conversations = initial
        selectedID = savedDrafts.flatMap { state in initial.contains { $0.id == state.selectedID } ? state.selectedID : nil } ?? initial[0].id
        let validIDs = Set(initial.map { $0.id.uuidString })
        drafts = (savedDrafts?.drafts ?? [:]).filter { validIDs.contains($0.key) && !$0.value.isEmpty }
        // Give a newly created empty chat a durable ID before saving its first draft.
        if loaded.isEmpty { save() }
    }

    func newConversation() {
        stop()
        if let empty = conversations.first(where: { !$0.isPinned && $0.messages.isEmpty && draft(for: $0.id).isEmpty }) { selectedID = empty.id }
        else { let chat = TutorConversation(); conversations.insert(chat, at: 0); selectedID = chat.id }
        draftStateDirty = true
        errorMessage = nil; notice = nil
        save()
    }
    func select(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        stop(); selectedID = id; errorMessage = nil; notice = nil
        draftStateDirty = true
        flushDrafts()
    }
    func delete(_ id: UUID) {
        if selectedID == id { stop() }
        conversations.removeAll { $0.id == id }
        drafts.removeValue(forKey: id.uuidString)
        draftStateDirty = true
        if conversations.isEmpty { conversations = [TutorConversation()] }
        if !conversations.contains(where: { $0.id == selectedID }) { selectedID = conversations[0].id }
        save()
    }
    func togglePin(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinnedAt = conversations[index].isPinned ? nil : Date()
        save()
    }
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isResponding, !text.isEmpty else { return }
        guard text.utf8.count <= 16000 else { errorMessage = "Please send a shorter question (under 16,000 bytes)."; return }
        draft = ""; errorMessage = nil; notice = nil
        let user = TutorMessage(role: .user, text: text)
        editCurrent { $0.messages.append(user) }
        save()
        generate()
    }
    func retry() {
        guard !isResponding, let index = current.messages.lastIndex(where: { $0.role == .user }) else { return }
        editCurrent { $0.messages = Array($0.messages.prefix(index + 1)) }
        errorMessage = nil; notice = nil; generate()
    }
    private func generate() {
        let prompt = messages
        let assistant = TutorMessage(role: .assistant, text: "")
        editCurrent { $0.messages.append(assistant) }
        isResponding = true; generationStatus = .waiting; runID = UUID()
        let id = runID
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.reply(messages: prompt, onStatus: { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.runID == id, self.isResponding else { return }
                        self.generationStatus = status
                    }
                }) { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.runID == id, self.isResponding else { return }
                        self.updateMessage(assistant.id, text: text)
                    }
                }
                guard runID == id else { return }
                updateMessage(assistant.id, text: response)
                isResponding = false; generationStatus = nil; task = nil; save()
            } catch {
                guard runID == id else { return }
                isResponding = false; generationStatus = nil; task = nil
                if error is CancellationError || (error as? AgentTransportError) == .cancelled { notice = "Response stopped." }
                else { errorMessage = error.localizedDescription.replacingOccurrences(of: "agent", with: "tutor") }
                removeEmptyReply(); save()
            }
        }
    }
    func stop() {
        guard isResponding else { return }
        runID = UUID(); task?.cancel(); task = nil; isResponding = false; generationStatus = nil
        notice = "Response stopped."; removeEmptyReply(); save()
    }
    func waitUntilIdle() async { await task?.value }
    private func updateMessage(_ id: UUID, text: String) {
        editCurrent { chat in
            if let index = chat.messages.firstIndex(where: { $0.id == id }) { chat.messages[index].text = text }
        }
    }
    private func removeEmptyReply() { editCurrent { $0.messages.removeAll { $0.role == .assistant && $0.text.isEmpty } } }
    private func editCurrent(_ change: (inout TutorConversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&conversations[index]); conversations[index].updatedAt = Date()
        transcriptRevision &+= 1
    }
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            self?.flushDrafts()
        }
    }

    /// Flush on chat transitions and when the app becomes inactive, not only after debounce.
    func flushDrafts() {
        draftSaveTask?.cancel(); draftSaveTask = nil
        guard draftStateDirty else { return }
        do {
            try FileManager.default.createDirectory(at: draftsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(DraftState(selectedID: selectedID, drafts: drafts))
            try data.write(to: draftsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            draftStateDirty = false
        } catch {
            errorMessage = "Your unfinished message could not be saved on this device. \(error.localizedDescription)"
        }
    }

    private func save() {
        conversations.sort(by: TutorConversation.historyOrder)
        // Retain pinned, active, and unfinished chats when pruning old completed history.
        if conversations.count > 100 {
            let protected = conversations.filter { $0.isPinned || $0.id == selectedID || !draft(for: $0.id).isEmpty }
            let protectedIDs = Set(protected.map(\.id))
            let remaining = conversations.filter { !protectedIDs.contains($0.id) }
            conversations = (protected + remaining.prefix(max(0, 100 - protected.count))).sorted(by: TutorConversation.historyOrder)
        }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(conversations)
            try data.write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { errorMessage = "This chat could not be saved on this device. \(error.localizedDescription)" }
        flushDrafts()
    }
}
