import Foundation
import Observation

@Observable
@MainActor
final class TutorSession {
    private(set) var conversations: [TutorConversation]
    private(set) var selectedID: UUID
    var draft = ""
    private(set) var isResponding = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private let client: any TutorCompleting
    private let storageURL: URL

    var current: TutorConversation { conversations.first { $0.id == selectedID } ?? conversations[0] }
    var messages: [TutorMessage] { current.messages }

    init(client: any TutorCompleting = CalculatingTutorClient.shared, storageURL: URL? = nil) {
        self.client = client
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageURL = storageURL ?? support.appendingPathComponent("lilC/edsger-conversations.json")
        let loaded = (try? Data(contentsOf: self.storageURL)).flatMap { try? JSONDecoder().decode([TutorConversation].self, from: $0) } ?? []
        let initial = loaded.isEmpty ? [TutorConversation()] : Array(loaded.prefix(100))
        conversations = initial
        selectedID = initial[0].id
    }

    func newConversation() {
        stop()
        if let empty = conversations.first(where: { $0.messages.isEmpty }) { selectedID = empty.id }
        else { let chat = TutorConversation(); conversations.insert(chat, at: 0); selectedID = chat.id }
        draft = ""; errorMessage = nil; notice = nil
        save()
    }
    func select(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        stop(); selectedID = id; draft = ""; errorMessage = nil; notice = nil
    }
    func delete(_ id: UUID) {
        if selectedID == id { stop() }
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { conversations = [TutorConversation()] }
        if !conversations.contains(where: { $0.id == selectedID }) { selectedID = conversations[0].id; draft = "" }
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
        isResponding = true; runID = UUID()
        let id = runID
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await client.reply(messages: prompt) { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.runID == id, self.isResponding else { return }
                        self.updateMessage(assistant.id, text: text)
                    }
                }
                guard runID == id else { return }
                updateMessage(assistant.id, text: response)
                isResponding = false; task = nil; save()
            } catch {
                guard runID == id else { return }
                isResponding = false; task = nil
                if error is CancellationError || (error as? AgentTransportError) == .cancelled { notice = "Response stopped." }
                else { errorMessage = error.localizedDescription.replacingOccurrences(of: "agent", with: "tutor") }
                removeEmptyReply(); save()
            }
        }
    }
    func stop() {
        guard isResponding else { return }
        runID = UUID(); task?.cancel(); task = nil; isResponding = false
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
    }
    private func save() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
        // Bound local history size while preserving the active conversation.
        if conversations.count > 100 { conversations = Array(conversations.prefix(100)) }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(conversations)
            try data.write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { errorMessage = "This chat could not be saved on this device. \(error.localizedDescription)" }
    }
}
