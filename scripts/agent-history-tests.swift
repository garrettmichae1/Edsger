import Foundation

private struct Failure: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw Failure(message: message) }
}
private func rejected(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failure(message: "Unsafe operation unexpectedly succeeded")
}

#if os(Linux)
// Only unavailable platform/model boundaries are stubs. Workspace, session,
// checkpoints, journals, source refresh, and conversation persistence are real.
final class LocalPythonRunner: LocalScriptRunning, @unchecked Sendable {
    func stop() {}; func input(_ line: String) {}; func eof() {}
    func run(path: URL, root: URL, onOutput: @escaping @Sendable (String) -> Void,
             onWaiting: @escaping @Sendable (Bool) -> Void) -> ScriptRunResult {
        .init(output: "", failed: false, stopped: false)
    }
}
typealias LocalJavaScriptRunner = LocalPythonRunner
typealias LocalLuaRunner = LocalPythonRunner
@MainActor final class AgentSettingsStore {
    var canRunAgents = true
    var safeguardsOn = true
}
struct LocalAgentClient: AgentCompleting {
    static let shared = Self()
    func complete(messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion {
        throw AgentTransportError.cancelled
    }
}
// Cloud/Keychain/SymPy are platform boundaries in this Linux persistence harness.
// The actual BYOK store, transport and credential policy have separate host tests.
@MainActor final class BYOKStore {
    static let shared = BYOKStore()
    func agentChoice(language: ProgrammingLanguage, project: String) -> BYOKChoice? { nil }
    func title(_ choice: BYOKChoice) -> String { choice.modelID }
    func selectAgent(_ choice: BYOKChoice?, language: ProgrammingLanguage, project: String) {}
    func client(for choice: BYOKChoice) throws -> LocalAgentClient { throw BYOKError.relayUnavailable }
    func beginRun() throws {}
    func endRun() {}
}
actor LocalMathCalculator {
    static let shared = LocalMathCalculator()
    func calculate(_ request: MathRequest) throws -> MathCalculation { throw BYOKError.relayUnavailable }
}

#endif

private final class FailedInstallFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at source: URL, to destination: URL) throws {
        if source.lastPathComponent == "staged" { throw Failure(message: "Simulated failed install") }
        try super.moveItem(at: source, to: destination)
    }
}

@main
private struct AgentHistoryTests {
    @MainActor static func main() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace")
        try write("int original;\r\n", root.appendingPathComponent("project/main.c"))
        try write("header", root.appendingPathComponent("project/include/搜索.h"))
        try write("other", root.appendingPathComponent("other/main.c"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project/empty"), withIntermediateDirectories: true)
        let binary = Data([0, 255, 128, 10])
        try binary.write(to: root.appendingPathComponent("project/data.bin"))
        let store = AgentProjectHistoryStore(workspaceURL: root)
        let before = try store.capture(project: "project", request: "Update the program", selectedFile: "project/main.c")
        try write("changed", root.appendingPathComponent("project/main.c"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("project/include"))
        try write("new", root.appendingPathComponent("project/new.c"))
        try check(try store.hasChanges(since: before.id), "Changed project was not detected")
        let reloaded = AgentProjectHistoryStore(workspaceURL: root)
        let recovery = try reloaded.restore(reloaded.checkpoint(id: before.id), currentSelection: "project/new.c")
        try check(try Data(contentsOf: root.appendingPathComponent("project/main.c")) == Data("int original;\r\n".utf8), "Source bytes/line endings were not restored")
        try check(try Data(contentsOf: root.appendingPathComponent("project/data.bin")) == binary, "Binary file changed")
        try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("project/include/搜索.h").path), "Deleted nested helper was not restored")
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("project/new.c").path), "New files survived rollback")
        try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("project/empty").path), "Empty folder was lost")
        try check(try String(contentsOf: root.appendingPathComponent("other/main.c"), encoding: .utf8) == "other", "Another project was changed")
        _ = try store.restore(recovery, currentSelection: "project/main.c")
        try check(try String(contentsOf: root.appendingPathComponent("project/main.c"), encoding: .utf8) == "changed", "Undo rollback lost later edits")
        print("PASS: persistent multi-file rollback, binary/Unicode/CRLF, nested/empty folders, isolation, and undo rollback")

        let failStore = AgentProjectHistoryStore(workspaceURL: root, fileManager: FailedInstallFileManager())
        try rejected { _ = try failStore.restore(before, currentSelection: "project/main.c") }
        try check(try String(contentsOf: root.appendingPathComponent("project/main.c"), encoding: .utf8) == "changed", "Failed install changed live files")
        try store.recoverPendingRestore()
        try rejected { _ = try store.capture(project: "../other", request: "unsafe", selectedFile: "") }
        let malicious = AgentProjectCheckpoint(id: UUID(), project: "project", createdAt: Date(), request: "bad", selectedFile: "", isRecovery: false, directories: [], contents: ["../escape.c": Data()])
        try rejected { _ = try store.restore(malicious, currentSelection: "") }
        let link = root.appendingPathComponent("project/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)
        try rejected { _ = try store.capture(project: "project", request: "unsafe", selectedFile: "") }
        try FileManager.default.removeItem(at: link)
        let blockedRoot = parent.appendingPathComponent("blocked")
        try write("old", blockedRoot.appendingPathComponent("main.c"))
        let blocked = AgentProjectHistoryStore(workspaceURL: blockedRoot)
        try write("not a directory", blocked.metadataURL)
        try rejected { _ = try blocked.capture(project: "", request: "storage failure", selectedFile: "main.c") }
        try check(try String(contentsOf: blockedRoot.appendingPathComponent("main.c"), encoding: .utf8) == "old", "Failed checkpoint changed files")
        print("PASS: failed swap recovery, traversal/corrupt payload/symlink rejection, and checkpoint storage failure")

        // Simulate an app termination after moving the original but before install.
        let transactionID = UUID()
        let transaction = store.metadataURL.appendingPathComponent("transactions/" + transactionID.uuidString)
        try FileManager.default.createDirectory(at: transaction.appendingPathComponent("staged"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("project"), to: transaction.appendingPathComponent("original"))
        try JSONSerialization.data(withJSONObject: ["project": "project", "transactionID": transactionID.uuidString])
            .write(to: store.metadataURL.appendingPathComponent("restore-journal.json"), options: .atomic)
        try store.recoverPendingRestore()
        try check(try String(contentsOf: root.appendingPathComponent("project/main.c"), encoding: .utf8) == "changed", "Interrupted swap did not recover original")
        try check(!FileManager.default.fileExists(atPath: transaction.path), "Recovered transaction was not cleaned up")
        print("PASS: restart recovery after interrupted directory swap")

        let installedID = UUID()
        let installed = store.metadataURL.appendingPathComponent("transactions/" + installedID.uuidString)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("project"), to: installed.appendingPathComponent("staged"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("project"), to: installed.appendingPathComponent("original"))
        try FileManager.default.moveItem(at: installed.appendingPathComponent("staged"), to: root.appendingPathComponent("project"))
        try JSONSerialization.data(withJSONObject: ["project": "project", "transactionID": installedID.uuidString])
            .write(to: store.metadataURL.appendingPathComponent("restore-journal.json"), options: .atomic)
        try store.recoverPendingRestore()
        try check(try String(contentsOf: root.appendingPathComponent("project/main.c"), encoding: .utf8) == "changed", "Completed install was lost during startup cleanup")
        try check(!FileManager.default.fileExists(atPath: installed.path), "Installed restore journal was not cleaned up")
        print("PASS: restart cleanup after an installed restore")

        let suiteName = "agent-history-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = LocalCWorkspace(defaults: defaults, directoryURL: root)
        _ = workspace.agentSelectFile("project/main.c")
        let selected = workspace.selectedFileID
        let point = try workspace.makeAgentCheckpoint(project: "project", request: "Replace code")
        _ = workspace.agentWriteFile("project/main.c", contents: "new task")
        _ = workspace.agentWriteFile("project/added.h", contents: "new helper")
        let user = AgentChatMessage(role: .user, text: "Replace code")
        let conversation = AgentSavedConversation(id: UUID(), project: "project", updatedAt: Date(), messages: [user, .init(role: .assistant, text: "Done")])
        let other = AgentSavedConversation(id: UUID(), project: "other", updatedAt: Date(), messages: [.init(role: .user, text: "Other project")])
        try store.saveConversations([conversation, other])
        let session = AgentSession(workspace: workspace, settings: AgentSettingsStore())
        try check(session.conversationID == conversation.id && session.conversationHistory.count == 1, "Project history loaded the wrong conversation")
        session.newConversation()
        try check(session.messages.isEmpty && session.conversationHistory.contains(where: { $0.id == conversation.id }), "New chat destroyed old history")
        session.openConversation(conversation)
        try check(session.messages.first?.id == user.id, "Opening history changed message identity")
        session.restore(point)
        try check(workspace.selectedFileID == selected && workspace.currentFile.code == "changed", "Workspace state/selection was not refreshed after restore")
        try check(workspace.agentReadFile("project/added.h") == nil && session.messages.isEmpty, "Restored files or model context are stale")
        try check(session.conversationHistory.contains(where: { $0.id == conversation.id }), "Rollback destroyed conversation history")
        let resumed = AgentSession(workspace: workspace, settings: AgentSettingsStore())
        try check(AgentTranscriptPresentation.visibleMessages(resumed.messages).isEmpty, "Restart revived stale tool context after rollback")
        try check(resumed.restorePoints.contains(where: { $0.isRecovery }), "Recovery action did not survive app restart")
        let backup = try resumed.restorePoints.first(where: { $0.isRecovery }).unwrap()
        resumed.restore(backup)
        try check(workspace.agentReadFile("project/main.c") == "new task" && workspace.agentReadFile("project/added.h") == "new helper", "Session undo rollback lost files")
        workspace.isRunning = true
        try rejected { _ = try workspace.restoreAgentCheckpoint(point) }
        try check(!resumed.canRestore, "Restore was enabled while a program was running")
        workspace.isRunning = false
        print("PASS: production workspace/session restore, fresh model context, history retention, restart, selection, and running guard")

        let rootPoint = try store.capture(project: "", request: "Root task", selectedFile: "project/main.c")
        try write("root addition", root.appendingPathComponent("root.c"))
        _ = try store.restore(rootPoint, currentSelection: "root.c")
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("root.c").path), "Root workspace restore did not remove additions")
        try check(try store.loadConversations().contains(where: { $0.id == conversation.id }), "Root rollback overwrote its metadata/history")
        print("PASS: root workspace rollback preserves checkpoints and conversations outside the restored tree")

        let archiveURL = store.metadataURL.appendingPathComponent("conversations.json")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: archiveURL)
        let damagedHistory = AgentSession(workspace: workspace, settings: AgentSettingsStore())
        try check(!damagedHistory.canManageConversations, "Corrupt history should not be overwritten by new chat")
        damagedHistory.newConversation()
        try check(try Data(contentsOf: archiveURL) == corrupt, "Corrupt history was destroyed")
        try write("externally changed", root.appendingPathComponent("project/main.c"))
        try rejected { _ = try workspace.makeAgentCheckpoint(project: "project", request: "Unsaved editor") }
        try rejected { _ = try workspace.restoreAgentCheckpoint(point) }
        print("PASS: corrupt history preservation and editor/disk mismatch rejection")

        let largeRoot = parent.appendingPathComponent("large")
        try write("source", largeRoot.appendingPathComponent("main.c"))
        try Data(count: 33 * 1024 * 1024).write(to: largeRoot.appendingPathComponent("artifact.bin"))
        let largeStore = AgentProjectHistoryStore(workspaceURL: largeRoot)
        try rejected { _ = try largeStore.capture(project: "", request: "Too large", selectedFile: "main.c") }
        try check(try String(contentsOf: largeRoot.appendingPathComponent("main.c"), encoding: .utf8) == "source", "Oversized capture altered source")
        print("PASS: oversized project fails before mutation")
        try conversationManagement(parent: parent)
    }

    @MainActor private static func conversationManagement(parent: URL) throws {
        let root = parent.appendingPathComponent("chat-management")
        let suiteName = "chat-management-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = LocalCWorkspace(defaults: defaults, directoryURL: root)
        _ = workspace.agentWriteFile("project/main.c", contents: "int main(void) { return 0; }")
        _ = workspace.agentSelectFile("project/main.c")
        let store = workspace.agentHistoryStore
        let older = AgentSavedConversation(id: UUID(), project: "project", updatedAt: Date(timeIntervalSince1970: 10), messages: [.init(role: .user, text: "Older chat")])
        let newer = AgentSavedConversation(id: UUID(), project: "project", updatedAt: Date(timeIntervalSince1970: 20), messages: [.init(role: .user, text: "Newer chat")])
        let other = AgentSavedConversation(id: UUID(), project: "other", updatedAt: Date(), messages: [.init(role: .user, text: "Another project")])
        let data = try JSONEncoder().encode([older, newer, other])
        try check(!String(decoding: data, as: UTF8.self).contains("pinnedAt"), "Legacy fixture contains pin field")
        try store.saveConversations(JSONDecoder().decode([AgentSavedConversation].self, from: data))
        let checkpoint = try workspace.makeAgentCheckpoint(project: "project", request: "Keep backup")
        let original = try Data(contentsOf: workspace.currentFileURL)
        let session = AgentSession(workspace: workspace, settings: AgentSettingsStore())
        session.draft = "Unsent work"
        session.toggleConversationPin(older.id)
        try check(session.conversationHistory.first?.id == older.id && session.conversationHistory.first?.isPinned == true, "Older pin did not move to top")
        try check(session.conversationID == newer.id && session.draft == "Unsent work", "Pin changed active conversation/draft")
        try check(session.conversationHistory.first?.updatedAt == older.updatedAt, "Pin changed activity timestamp")
        let reopened = AgentSession(workspace: workspace, settings: AgentSettingsStore())
        try check(reopened.conversationHistory.first?.isPinned == true, "Pin did not survive restart")
        reopened.openConversation(older)
        try check(reopened.conversationHistory.first?.isPinned == true, "Saving messages dropped pin")
        reopened.openConversation(newer)
        reopened.toggleConversationPin(older.id)
        try check(reopened.conversationHistory.first?.id == newer.id && !reopened.conversationHistory.contains(where: \.isPinned), "Unpin did not restore recency")
        reopened.toggleConversationPin(other.id)
        reopened.deleteConversation(other.id)
        try check(try store.loadConversations().first(where: { $0.id == other.id }) == other, "History operation crossed project boundary")
        reopened.draft = "Keep active draft"
        reopened.deleteConversation(older.id)
        try check(reopened.conversationID == newer.id && reopened.draft == "Keep active draft", "Deleting inactive chat disturbed active draft")
        reopened.openConversation(older)
        try check(reopened.conversationID == newer.id, "Stale row resurrected deleted chat")
        reopened.toggleConversationPin(newer.id)
        reopened.deleteConversation(newer.id)
        try check(reopened.conversationHistory.isEmpty && reopened.messages.isEmpty && reopened.draft.isEmpty, "Deleting active last chat did not clear session")
        let afterDelete = AgentSession(workspace: workspace, settings: AgentSettingsStore())
        try check(afterDelete.conversationHistory.isEmpty && !afterDelete.messages.contains(where: { $0.role == .user }), "Deleted chat returned after restart")
        try check(try Data(contentsOf: workspace.currentFileURL) == original, "Deleting chat changed project source")
        try check(try store.checkpoint(id: checkpoint.id).id == checkpoint.id, "Deleting chat removed restore point")
        print("PASS: agent legacy pins, order, persistence, unpin, project isolation, active/inactive deletion, stale row, restart, and backup preservation")

        // Pinned chats and the active chat must survive the ordinary 20-chat cap.
        let pinned = (0..<22).map { index in
            AgentSavedConversation(id: UUID(), project: "project", updatedAt: Date(timeIntervalSince1970: Double(index)), messages: [.init(role: .user, text: "Pinned \(index)")], pinnedAt: Date(timeIntervalSince1970: Double(index)))
        }
        try store.saveConversations(pinned + [newer, other])
        try store.selectConversation(newer.id, project: "project")
        let retention = AgentSession(workspace: workspace, settings: AgentSettingsStore())
        try check(retention.conversationHistory.filter(\.isPinned).count == 22 && retention.conversationHistory.contains(where: { $0.id == newer.id }), "Pruning dropped pins or active conversation")

        // Failed writes must leave pin/delete state unchanged in memory.
        let archive = store.metadataURL.appendingPathComponent("conversations.json")
        let saved = try Data(contentsOf: archive)
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try write("block replacement", archive.appendingPathComponent("blocker"))
        let beforeFailure = retention.savedConversations
        retention.toggleConversationPin(newer.id)
        try check(retention.savedConversations == beforeFailure && retention.notice != nil, "Failed pin changed history")
        retention.deleteConversation(newer.id)
        try check(retention.savedConversations == beforeFailure && retention.conversationID == newer.id && retention.notice != nil, "Failed delete hid chat")
        try FileManager.default.removeItem(at: archive)
        try saved.write(to: archive)
        print("PASS: pinned retention beyond cap and failed pin/delete persistence preserves visible history")
    }

    private static func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw Failure(message: "Required test fixture missing") }
        return value
    }
}
