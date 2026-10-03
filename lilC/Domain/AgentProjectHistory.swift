import Foundation

enum AgentWorkspaceRecoveryError: LocalizedError {
    case running, unsaved, storage(String)
    var errorDescription: String? {
        switch self {
        case .running: "Stop the running program before changing or restoring this project."
        case .unsaved: "The editor and saved files differ. Reopen or save the project before asking the agent to change it."
        case .storage(let detail): "Project recovery needs attention: \(detail)"
        }
    }
}

struct AgentProjectCheckpoint: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let project: String
    let createdAt: Date
    let request: String
    let selectedFile: String
    let isRecovery: Bool
    let directories: [String]
    let contents: [String: Data]

    var info: AgentCheckpointInfo {
        .init(id: id, project: project, createdAt: createdAt, request: request, selectedFile: selectedFile, isRecovery: isRecovery)
    }
}

struct AgentCheckpointInfo: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let project: String
    let createdAt: Date
    let request: String
    let selectedFile: String
    let isRecovery: Bool
}

struct AgentSavedConversation: Codable, Identifiable, Equatable {
    let id: UUID
    let project: String
    var updatedAt: Date
    var messages: [AgentChatMessage]
    // Optional for archives created before pinning was available.
    var pinnedAt: Date?
    var isPinned: Bool { pinnedAt != nil }

    static func historyOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if let left = lhs.pinnedAt, let right = rhs.pinnedAt, left != right { return left > right }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    var title: String {
        let request = messages.first { $0.role == .user }?.text ?? "New chat"
        return String(request.replacingOccurrences(of: "\n", with: " ").prefix(70))
    }
}

enum AgentProjectHistoryError: LocalizedError {
    case invalidPath, symbolicLink, oversized, unreadable, pendingRestore, invalidCheckpoint
    var errorDescription: String? {
        switch self {
        case .invalidPath: "The project path is not safe to restore."
        case .symbolicLink: "Restore points do not support symbolic links. No files were changed."
        case .oversized: "This project exceeds the 32 MB or 5,000-file restore-point limit. No files were changed."
        case .unreadable: "Some project files could not be backed up. No files were changed."
        case .pendingRestore: "A previous restore needs recovery before the agent can change files."
        case .invalidCheckpoint: "This restore point could not be verified. No files were changed."
        }
    }
}

/// Stored beside, rather than inside, the language workspace so a root restore
/// cannot replace its own backups or conversation history. Main-actor callers
/// serialize app operations; the store itself also works in synchronous tests.
struct AgentProjectHistoryStore {
    let workspaceURL: URL
    let fileManager: FileManager
    private let maximumBytes = 32 * 1024 * 1024
    private let maximumEntries = 5_000

    init(workspaceURL: URL, fileManager: FileManager = .default) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.fileManager = fileManager
    }

    var metadataURL: URL {
        workspaceURL.deletingLastPathComponent().appendingPathComponent("." + workspaceURL.lastPathComponent + "-agent-state", isDirectory: true)
    }
    private var checkpointURL: URL { metadataURL.appendingPathComponent("checkpoints", isDirectory: true) }
    private var journalURL: URL { metadataURL.appendingPathComponent("restore-journal.json") }
    private func checkpointDirectory(_ id: UUID) -> URL {
        checkpointURL.appendingPathComponent(id.uuidString + ".checkpoint", isDirectory: true)
    }

    func checkpoints(project: String) throws -> [AgentCheckpointInfo] {
        guard fileManager.fileExists(atPath: checkpointURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: checkpointURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "checkpoint" }
            .map { try JSONDecoder().decode(AgentCheckpointInfo.self, from: Data(contentsOf: $0.appendingPathComponent("info.json"))) }
            .filter { $0.project == project }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    func checkpoint(id: UUID) throws -> AgentProjectCheckpoint {
        let value = try JSONDecoder().decode(AgentProjectCheckpoint.self, from: Data(contentsOf: checkpointDirectory(id).appendingPathComponent("snapshot.json")))
        guard value.id == id else { throw AgentProjectHistoryError.invalidCheckpoint }
        try verify(value)
        return value
    }

    func hasChanges(since id: UUID) throws -> Bool {
        let before = try checkpoint(id: id)
        let live = try readTree(projectURL(before.project))
        return Set(live.directories) != Set(before.directories) || live.contents != before.contents
    }

    func discard(id: UUID) throws {
        try fileManager.removeItem(at: checkpointDirectory(id))
    }

    @discardableResult
    func capture(project: String, request: String, selectedFile: String, isRecovery: Bool = false) throws -> AgentProjectCheckpoint {
        guard !fileManager.fileExists(atPath: journalURL.path) else { throw AgentProjectHistoryError.pendingRestore }
        let target = try projectURL(project)
        let tree = try readTree(target)
        let checkpoint = AgentProjectCheckpoint(id: UUID(), project: project, createdAt: Date(), request: String(request.prefix(300)),
                                                selectedFile: selectedFile, isRecovery: isRecovery, directories: tree.directories, contents: tree.contents)
        try verify(checkpoint)
        try fileManager.createDirectory(at: checkpointURL, withIntermediateDirectories: true)
        let pending = checkpointURL.appendingPathComponent(".capture-" + checkpoint.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: pending, withIntermediateDirectories: true)
        do {
            try JSONEncoder().encode(checkpoint).write(to: pending.appendingPathComponent("snapshot.json"), options: .atomic)
            try JSONEncoder().encode(checkpoint.info).write(to: pending.appendingPathComponent("info.json"), options: .atomic)
            try fileManager.moveItem(at: pending, to: checkpointDirectory(checkpoint.id))
        } catch {
            try? fileManager.removeItem(at: pending)
            throw error
        }
        return checkpoint
    }

    /// A recovery checkpoint is committed before any original file is moved.
    /// The journal distinguishes incomplete swaps from installed restores.
    @discardableResult
    func restore(_ checkpoint: AgentProjectCheckpoint, currentSelection: String) throws -> AgentProjectCheckpoint {
        try verify(checkpoint)
        guard !fileManager.fileExists(atPath: journalURL.path) else { throw AgentProjectHistoryError.pendingRestore }
        let target = try projectURL(checkpoint.project)
        let recovery = try capture(project: checkpoint.project, request: "Before rollback", selectedFile: currentSelection, isRecovery: true)
        let transactionID = UUID()
        let transaction = transactionURL(transactionID)
        let staged = transaction.appendingPathComponent("staged", isDirectory: true)
        let original = transaction.appendingPathComponent("original", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
            for path in checkpoint.directories.sorted(by: { $0.count < $1.count }) {
                try fileManager.createDirectory(at: staged.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
            }
            for (path, bytes) in checkpoint.contents {
                let url = staged.appendingPathComponent(path)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
            }
            let journal = RestoreJournal(project: checkpoint.project, transactionID: transactionID)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try fileManager.moveItem(at: target, to: original)
            do { try fileManager.moveItem(at: staged, to: target) }
            catch {
                try fileManager.moveItem(at: original, to: target)
                throw error
            }
            // The restore is installed. Leave a journal for startup recovery if
            // cleanup fails; never report an installed restore as a failed write.
            try? fileManager.removeItem(at: journalURL)
            if !fileManager.fileExists(atPath: journalURL.path) { try? fileManager.removeItem(at: transaction) }
            prune(project: checkpoint.project, preserving: [checkpoint.id, recovery.id])
            return recovery
        } catch {
            if fileManager.fileExists(atPath: journalURL.path) {
                try? recoverPendingRestore()
            } else { try? fileManager.removeItem(at: transaction) }
            if !fileManager.fileExists(atPath: journalURL.path), fileManager.fileExists(atPath: target.path) {
                // No restore was installed; avoid offering a misleading Undo
                // rollback entry for a failed attempt with unchanged files.
                try? discard(id: recovery.id)
            }
            throw error
        }
    }

    func recoverPendingRestore() throws {
        guard fileManager.fileExists(atPath: journalURL.path) else { return }
        let journal = try JSONDecoder().decode(RestoreJournal.self, from: Data(contentsOf: journalURL))
        let target = try projectURL(journal.project)
        let transaction = transactionURL(journal.transactionID)
        let original = transaction.appendingPathComponent("original")
        let staged = transaction.appendingPathComponent("staged")
        if !fileManager.fileExists(atPath: target.path) {
            guard fileManager.fileExists(atPath: original.path) else { throw AgentProjectHistoryError.pendingRestore }
            try fileManager.moveItem(at: original, to: target)
        } else if fileManager.fileExists(atPath: original.path) && fileManager.fileExists(atPath: staged.path) {
            // Both old and staged trees still exist, so the destination was not
            // installed by this transaction. Do not discard either tree.
            throw AgentProjectHistoryError.pendingRestore
        }
        try fileManager.removeItem(at: journalURL)
        try? fileManager.removeItem(at: transaction)
    }

    func prune(project: String, preserving: Set<UUID> = []) {
        guard let values = try? checkpoints(project: project) else { return }
        for old in values.dropFirst(10) where !preserving.contains(old.id) {
            try? fileManager.removeItem(at: checkpointDirectory(old.id))
        }
    }

    func loadConversations() throws -> [AgentSavedConversation] {
        let url = metadataURL.appendingPathComponent("conversations.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([AgentSavedConversation].self, from: Data(contentsOf: url))
    }

    func saveConversations(_ conversations: [AgentSavedConversation]) throws {
        try fileManager.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(conversations).write(to: metadataURL.appendingPathComponent("conversations.json"), options: .atomic)
    }

    func selectedConversation(project: String) throws -> UUID? {
        let url = metadataURL.appendingPathComponent("active-conversations.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: url))[project]
    }

    func selectConversation(_ id: UUID, project: String) throws {
        let url = metadataURL.appendingPathComponent("active-conversations.json")
        var selections: [String: UUID] = [:]
        if fileManager.fileExists(atPath: url.path) {
            selections = try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: url))
        }
        selections[project] = id
        try fileManager.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(selections).write(to: url, options: .atomic)
    }

    private struct RestoreJournal: Codable { let project: String; let transactionID: UUID }
    private func transactionURL(_ id: UUID) -> URL { metadataURL.appendingPathComponent("transactions/" + id.uuidString, isDirectory: true) }

    private func safePath(_ path: String, allowEmpty: Bool = false) -> Bool {
        if path.isEmpty { return allowEmpty }
        return !path.hasPrefix("/") && !path.contains("\0") && path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func projectURL(_ project: String) throws -> URL {
        guard safePath(project, allowEmpty: true) else { throw AgentProjectHistoryError.invalidPath }
        let target = project.isEmpty ? workspaceURL : workspaceURL.appendingPathComponent(project, isDirectory: true)
        // Reject symlinks in every ancestor, including the workspace itself.
        var cursor = workspaceURL
        try rejectSymbolicLink(cursor)
        for part in project.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            try rejectSymbolicLink(cursor)
        }
        return target
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw AgentProjectHistoryError.symbolicLink
        }
    }

    private func verify(_ checkpoint: AgentProjectCheckpoint) throws {
        guard safePath(checkpoint.project, allowEmpty: true), checkpoint.directories.count + checkpoint.contents.count <= maximumEntries,
              checkpoint.directories.allSatisfy({ safePath($0) }), checkpoint.contents.keys.allSatisfy({ safePath($0) }),
              checkpoint.contents.values.reduce(0, { $0 + $1.count }) <= maximumBytes else { throw AgentProjectHistoryError.invalidCheckpoint }
        let folders = Set(checkpoint.directories)
        let paths = Set(checkpoint.contents.keys)
        guard folders.count == checkpoint.directories.count, folders.isDisjoint(with: paths) else { throw AgentProjectHistoryError.invalidCheckpoint }
        for path in checkpoint.contents.keys {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !paths.contains(parent) else { throw AgentProjectHistoryError.invalidCheckpoint }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    private func readTree(_ root: URL) throws -> (directories: [String], contents: [String: Data]) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw AgentProjectHistoryError.unreadable }
        var failure: Error?
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, errorHandler: { _, error in failure = error; return false }) else { throw AgentProjectHistoryError.unreadable }
        var directories: [String] = []
        var contents: [String: Data] = [:]
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw AgentProjectHistoryError.symbolicLink }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard safePath(relative) else { throw AgentProjectHistoryError.invalidPath }
            if values.isDirectory == true { directories.append(relative) }
            else {
                guard values.isRegularFile == true else { throw AgentProjectHistoryError.unreadable }
                guard (values.fileSize ?? 0) <= maximumBytes - total else { throw AgentProjectHistoryError.oversized }
                let bytes = try Data(contentsOf: url)
                total += bytes.count
                guard total <= maximumBytes else { throw AgentProjectHistoryError.oversized }
                contents[relative] = bytes
            }
            guard directories.count + contents.count <= maximumEntries else { throw AgentProjectHistoryError.oversized }
        }
        if let failure { throw failure }
        return (directories, contents)
    }
}
