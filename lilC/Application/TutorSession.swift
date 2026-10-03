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
    private var documentDrafts: [String: ChatDocumentReference]
    private var draftStateDirty = false
    private var draftSaveTask: Task<Void, Never>?
    private var documentContextUndo: DocumentContextUndo?
    private struct DocumentContextUndo {
        let conversationID: UUID
        let startIndex: Int?
        let pending: ChatDocumentReference?
    }

    private struct DraftState: Codable {
        var selectedID: UUID
        var drafts: [String: String]
        var documents: [String: ChatDocumentReference]?
    }

    func draft(for id: UUID) -> String { drafts[id.uuidString] ?? "" }

    var current: TutorConversation { conversations.first { $0.id == selectedID } ?? conversations[0] }
    var messages: [TutorMessage] { current.messages }
    func documentDraft(for id: UUID) -> ChatDocumentReference? { documentDrafts[id.uuidString] }
    var pendingDocument: ChatDocumentReference? { documentDraft(for: selectedID) }
    private var contextMessages: [TutorMessage] {
        Array(messages.dropFirst(current.documentContextStartIndex ?? 0))
    }
    var activeDocument: ChatDocumentReference? { contextMessages.last(where: { $0.role == .user && $0.document != nil })?.document }
    var canUndoDocumentContext: Bool { documentContextUndo?.conversationID == selectedID && !isResponding }

    /// Leave the file without deleting its messages or shared imported original.
    func clearDocumentContext() {
        guard pendingDocument != nil || activeDocument != nil else { return }
        let undo = DocumentContextUndo(conversationID: selectedID, startIndex: current.documentContextStartIndex, pending: pendingDocument)
        let wasActive = activeDocument != nil
        stop()
        documentDrafts[selectedID.uuidString] = nil
        draftStateDirty = true
        // Removing an unsent attachment alone must not discard ordinary-chat context.
        setDocumentContextStart(wasActive ? messages.count : undo.startIndex)
        documentContextUndo = undo
        errorMessage = nil
        notice = "Document context cleared."
        save()
    }

    func undoClearDocumentContext() {
        guard canUndoDocumentContext, let undo = documentContextUndo else { return }
        setDocumentContextStart(undo.startIndex)
        documentDrafts[selectedID.uuidString] = undo.pending
        draftStateDirty = true
        documentContextUndo = nil
        notice = nil; errorMessage = nil
        save()
    }

    private func setDocumentContextStart(_ index: Int?) {
        guard let chat = conversations.firstIndex(where: { $0.id == selectedID }) else { return }
        conversations[chat].documentContextStartIndex = index
    }
    func attach(_ document: ChatDocumentReference?) {
        documentContextUndo = nil
        if notice == "Document context cleared." { notice = nil }
        documentDrafts[selectedID.uuidString] = document
        draftStateDirty = true
        flushDrafts()
    }

    init(client: any TutorCompleting = SelectedChatClient.shared, storageURL: URL? = nil) {
        self.client = client
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lilC/edsger-conversations.json")
        self.draftsURL = self.storageURL.deletingPathExtension().appendingPathExtension("drafts.json")
        let loaded = (try? Data(contentsOf: self.storageURL)).flatMap { try? JSONDecoder().decode([TutorConversation].self, from: $0) } ?? []
        let savedDrafts = (try? Data(contentsOf: self.draftsURL)).flatMap { try? JSONDecoder().decode(DraftState.self, from: $0) }
        var initial = loaded.isEmpty ? [TutorConversation()] : loaded.sorted(by: TutorConversation.historyOrder)
        // Reject a malformed persisted boundary before dropFirst or future appends use it.
        for index in initial.indices {
            if let start = initial[index].documentContextStartIndex, !(0...initial[index].messages.count).contains(start) {
                initial[index].documentContextStartIndex = nil
            }
        }
        conversations = initial
        selectedID = savedDrafts.flatMap { state in initial.contains { $0.id == state.selectedID } ? state.selectedID : nil } ?? initial[0].id
        let validIDs = Set(initial.map { $0.id.uuidString })
        drafts = (savedDrafts?.drafts ?? [:]).filter { validIDs.contains($0.key) && !$0.value.isEmpty }
        documentDrafts = (savedDrafts?.documents ?? [:]).filter { validIDs.contains($0.key) }
        // Give a newly created empty chat a durable ID before saving its first draft.
        if loaded.isEmpty { save() }
    }

    func newConversation() {
        documentContextUndo = nil
        stop()
        if let empty = conversations.first(where: { !$0.isPinned && $0.messages.isEmpty && draft(for: $0.id).isEmpty && documentDrafts[$0.id.uuidString] == nil }) { selectedID = empty.id }
        else { let chat = TutorConversation(); conversations.insert(chat, at: 0); selectedID = chat.id }
        draftStateDirty = true
        errorMessage = nil; notice = nil
        save()
    }
    func select(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        documentContextUndo = nil
        stop(); selectedID = id; errorMessage = nil; notice = nil
        draftStateDirty = true
        flushDrafts()
    }
    func delete(_ id: UUID) {
        if documentContextUndo?.conversationID == id { documentContextUndo = nil }
        if selectedID == id { stop() }
        conversations.removeAll { $0.id == id }
        drafts.removeValue(forKey: id.uuidString)
        documentDrafts.removeValue(forKey: id.uuidString)
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
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = typed.isEmpty && pendingDocument != nil ? "Give me an overview of this document." : typed
        guard !isResponding, !text.isEmpty else { return }
        guard (pendingDocument ?? activeDocument) == nil || text.utf8.count <= DocumentLimits.questionBytes else {
            errorMessage = "For file questions, use a focused question under 2,000 bytes."; return
        }
        guard text.utf8.count <= 16000 else { errorMessage = "Please send a shorter question (under 16,000 bytes)."; return }
        draft = ""; errorMessage = nil; notice = nil
        let user = TutorMessage(role: .user, text: text, document: pendingDocument)
        attach(nil)
        editCurrent { $0.messages.append(user) }
        save()
        generate()
    }
    func retry() {
        guard !isResponding, let index = current.messages.lastIndex(where: { $0.role == .user }) else { return }
        // A retry must not resurrect a document turn that was explicitly left behind.
        guard index >= (current.documentContextStartIndex ?? 0) else { return }
        documentContextUndo = nil
        editCurrent { $0.messages = Array($0.messages.prefix(index + 1)) }
        errorMessage = nil; notice = nil; generate()
    }
    private func generate() {
        let prompt = contextMessages
        let assistant = TutorMessage(role: .assistant, text: "")
        editCurrent { $0.messages.append(assistant) }
        isResponding = true; generationStatus = .waiting; runID = UUID()
        let id = runID
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let onStatus: GenerationStatusHandler = { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.runID == id, self.isResponding else { return }
                        self.generationStatus = status
                    }
                }
                let onUpdate: @Sendable (String) -> Void = { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.runID == id, self.isResponding else { return }
                        self.updateMessage(assistant.id, text: text)
                    }
                }
                let response: String
                if let documentClient = client as? any DocumentTutorCompleting {
                    response = try await documentClient.replyWithDocuments(messages: prompt, onStatus: onStatus, onSources: { [weak self] sources in
                        await MainActor.run {
                            guard let self, self.runID == id, self.isResponding else { return }
                            self.editCurrent { chat in
                                if let index = chat.messages.firstIndex(where: { $0.id == assistant.id }) { chat.messages[index].sources = sources }
                            }
                        }
                    }, onUpdate: onUpdate)
                } else {
                    response = try await client.reply(messages: prompt, onStatus: onStatus, onUpdate: onUpdate)
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
            let data = try JSONEncoder().encode(DraftState(selectedID: selectedID, drafts: drafts, documents: documentDrafts))
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
            let protected = conversations.filter { $0.isPinned || $0.id == selectedID || !draft(for: $0.id).isEmpty || documentDrafts[$0.id.uuidString] != nil }
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
