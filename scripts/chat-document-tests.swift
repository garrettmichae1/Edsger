import Foundation
import ZIPFoundation

private struct Failure: Error { let description: String }
private func check(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}
private func rejects(_ operation: () throws -> Void, _ message: String) throws {
    do { try operation() } catch { return }
    throw Failure(description: "Accepted invalid input: " + message)
}
@MainActor private func rejectsAsync(_ operation: () async throws -> Void, _ message: String) async throws {
    do { try await operation() } catch { return }
    throw Failure(description: "Accepted invalid input: " + message)
}
private actor RecordingTutor: TutorCompleting {
    private(set) var requests: [[TutorMessage]] = []
    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        requests.append(messages); onUpdate("Fixture answer [1]"); return "Fixture answer [1]"
    }
}
private actor SourceRecorder {
    var sources: [ChatDocumentSource] = []
    func set(_ sources: [ChatDocumentSource]) { self.sources = sources }
}
private actor LateDocumentTutor: DocumentTutorCompleting {
    private(set) var started = false
    let sources: [ChatDocumentSource]
    init(sources: [ChatDocumentSource]) { self.sources = sources }
    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String { "Late" }
    func replyWithDocuments(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
                            onSources: @escaping @Sendable ([ChatDocumentSource]) async -> Void,
                            onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        started = true
        try? await Task.sleep(for: .milliseconds(80))
        await onSources(sources); onUpdate("Late")
        return "Late"
    }
}
private struct DefaultTutor: TutorCompleting {
    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String { "Default" }
}
enum SelectedChatClient { static let shared: any TutorCompleting = DefaultTutor() }

private func reference(_ name: String = "notes.txt") -> ChatDocumentReference {
    .init(id: UUID(), name: name, kind: "txt", byteCount: 100, characterCount: 100, pageCount: nil,
          preview: "Preview", importedAt: Date(), note: "Plain text only.")
}
private let namespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
private func wordXML(_ body: String) -> Data {
    Data("<w:document xmlns:w=\"\(namespace)\"><w:body>\(body)</w:body></w:document>".utf8)
}
private func zip(_ url: URL, entries: [(String, Data)], symlink: Bool = false) throws {
    let archive = try Archive(url: url, accessMode: .create)
    for (path, data) in entries {
        try archive.addEntry(with: path, type: symlink ? .symlink : .file, uncompressedSize: Int64(data.count),
                             compressionMethod: .deflate, provider: { position, size in
            data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
        })
    }
}

@main private struct DocumentTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try check(try DocumentText.decode(Data("\u{FEFF}Hello\r\nworld\r".utf8)) == "Hello\nworld", "UTF8/CRLF")
        var utf16 = Data([0xff, 0xfe]); utf16.append("Résumé ✓".data(using: .utf16LittleEndian)!)
        try check(try DocumentText.decode(utf16) == "Résumé ✓", "UTF16")
        try rejects({ _ = try DocumentText.decode(Data([0xff, 0x00])) }, "invalid UTF8")
        try rejects({ _ = try DocumentText.decode(Data("Binary\0text".utf8)) }, "binary")
        try rejects({ _ = try DocumentText.decode(Data(" \n".utf8)) }, "empty")
        try rejects({ _ = try DocumentText.decode(Data(String(repeating: "x", count: 50_001).utf8)) }, "length")
        try check(try DocumentText.decode(Data(String(repeating: "x", count: 50_000).utf8)).count == 50_000, "length boundary")
        try rejects({ _ = try DocumentText.clean("a" + String(repeating: "\u{0301}", count: 400)) }, "oversized grapheme")
        print("PASS text encodings, normalization, binary rejection and character boundaries")

        let body = "<w:p><w:r><w:t>Hello</w:t><w:tab/><w:t>world</w:t></w:r></w:p><w:del><w:p><w:r><w:t>deleted</w:t></w:r></w:p></w:del><w:ins><w:p><w:r><w:t>inserted</w:t></w:r></w:p></w:ins><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell &amp; value</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
        let xml = wordXML(body)
        let extracted = try WordDocumentText.extract(xml)
        try check(extracted.contains("Hello\tworld") && extracted.contains("Cell & value") && extracted.contains("inserted") && !extracted.contains("deleted"), "paragraph, table, tracking")
        let strict = String(decoding: xml, as: UTF8.self).replacingOccurrences(of: namespace, with: "http://purl.oclc.org/ooxml/wordprocessingml/main")
        try check(try WordDocumentText.extract(Data(strict.utf8)) == extracted, "strict Word namespace")
        try rejects({ _ = try WordDocumentText.extract(Data("<!DOCTYPE doc [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><doc>&x;</doc>".utf8)) }, "entity/DTD")
        let utf32Entity = "<!DOCTYPE doc [<!ENTITY x 'expanded'>]><doc>&x;</doc>".data(using: .utf32)!
        try rejects({ _ = try WordDocumentText.extract(utf32Entity) }, "UTF32 entity declaration")
        try rejects({ _ = try WordDocumentText.extract(wordXML("<w:p>")) }, "malformed XML")
        try rejects({ _ = try WordDocumentText.extract(wordXML("<oMath/>")) }, "equation")
        try rejects({ _ = try WordDocumentText.extract(wordXML("<w:altChunk/>")) }, "embedded import")
        try check(try WordDocumentText.extract(wordXML("<w:drawing><w:t>hidden</w:t></w:drawing><w:p><w:r><w:t>body</w:t></w:r></w:p>")) == "body", "drawing text excluded")
        print("PASS namespace-aware Word text/table extraction, track changes, XML/entity/equation rejection")

        let docRoot = root.appendingPathComponent("library")
        let store = ChatDocumentStore(root: docRoot)
        let txt = root.appendingPathComponent("contract.txt")
        try "The renewal deadline is March 17.\n\nThe cancellation fee is 125 dollars.".write(to: txt, atomically: true, encoding: .utf8)
        let a = try await store.importFile(txt)
        let docx = root.appendingPathComponent("basic.docx")
        try zip(docx, entries: [("word/document.xml", xml), ("irrelevant/../entry", Data("ignored".utf8))])
        let word = try await store.importFile(docx)
        try check(try await store.read(word.id).sections.map(\.text).joined().contains("Cell & value"), "deflated ZIP Word extraction")
        let reopened = ChatDocumentStore(root: docRoot)
        let reopenedText = try await reopened.read(a.id)
        try check(await reopened.recent().count == 2 && reopenedText.reference == a, "reopen references/text")
        let tooBig = root.appendingPathComponent("big.txt")
        try Data(repeating: 65, count: DocumentLimits.fileBytes + 1).write(to: tooBig)
        let empty = root.appendingPathComponent("empty.txt"); try Data().write(to: empty)
        let legacy = root.appendingPathComponent("old.doc"); try Data([1,2]).write(to: legacy)
        let duplicate = root.appendingPathComponent("duplicate.docx"); try zip(duplicate, entries: [("word/document.xml", xml), ("word/document.xml", xml)])
        let link = root.appendingPathComponent("link.docx"); try zip(link, entries: [("word/document.xml", xml)], symlink: true)
        let bomb = root.appendingPathComponent("bomb.docx"); try zip(bomb, entries: [("word/document.xml", Data(repeating: 65, count: DocumentLimits.xmlBytes + 1))])
        let corrupt = root.appendingPathComponent("corrupt.docx")
        try zip(corrupt, entries: [("word/document.xml", xml)])
        var corrupted = try Data(contentsOf: corrupt)
        // Mutate central-directory CRC: extraction must compare it to the decompressed data.
        let signature = Data([0x50,0x4b,0x01,0x02]); let central = corrupted.range(of: signature)!.lowerBound
        corrupted[central + 16] ^= 0xff; try corrupted.write(to: corrupt)
        for invalid in [tooBig, empty, legacy, duplicate, link, bomb, corrupt] {
            try await rejectsAsync({ _ = try await store.importFile(invalid) }, invalid.lastPathComponent)
        }
        try check(await store.recent().count == 2, "rejected imports polluted catalog")
        try check(try FileManager.default.contentsOfDirectory(at: docRoot, includingPropertiesForKeys: nil).count == 3, "rejected import directory cleanup")
        let cancelled = Task { try await store.importFile(txt) }; cancelled.cancel()
        try await rejectsAsync({ _ = try await cancelled.value }, "cancellation")
        print("PASS bounded ZIP imports, CRC validation, duplicate/symlink rejection, cancellation, cleanup and persistence")

        let contract = try await store.read(a.id)
        let sources = DocumentRetrieval.sources(document: contract, question: "What is the cancellation fee?")
        try check(sources.contains { $0.text.contains("125 dollars") }, "retrieval exact term")
        try check(DocumentRetrieval.sources(document: contract, question: "quasar astrophysics").isEmpty, "no evidence fallback")
        try check(DocumentRetrieval.sources(document: contract, question: "Why?", previousQuestion: "cancellation fee").contains { $0.text.contains("125 dollars") }, "short followup context")
        let multilingual = ExtractedDocument(reference: reference(), sections: [.init(location: "Paragraph 1", text: String(repeating: "日本語資料 ", count: 100) + " zebratarget 42")])
        let multiSources = DocumentRetrieval.sources(document: multilingual, question: "zebratarget")
        try check(multiSources.contains { $0.text.contains("zebratarget") }, "Unicode chunks must not lose the matching tail")
        let overview = DocumentRetrieval.sources(document: multilingual, question: "summarize")
        try check(overview.count <= 4 && overview.reduce(0) { $0 + $1.text.utf8.count } <= 2_600, "bounded Unicode evidence")
        let prompt = try DocumentRetrieval.prompt(question: "Question", sources: sources, note: a.note)
        try check(prompt.contains("untrusted quoted data") && prompt.contains("explicitly limited") && prompt.contains("no calculator was run"), "grounding instructions")
        print("PASS precise retrieval, Unicode coverage, followups, explicit partial summaries and bounded evidence")

        let ordinary = RecordingTutor(); let grounded = RecordingTutor(); let recorder = SourceRecorder()
        let client = DocumentTutorClient(tutor: ordinary, documentTutor: grounded, documents: store)
        let plain: [TutorMessage] = [.init(role: .user, text: "2 + 2")]
        _ = try await client.reply(messages: plain, onUpdate: { _ in })
        let groundedEmpty = await grounded.requests.isEmpty
        try check(await ordinary.requests == [plain] && groundedEmpty, "normal routing unchanged")
        var thread: [TutorMessage] = [.init(role: .user, text: "cancellation fee", document: a), .init(role: .assistant, text: "Old file answer: SECRET_OLD")]
        _ = try await client.replyWithDocuments(messages: thread, onStatus: { _ in }, onSources: { await recorder.set($0) }, onUpdate: { _ in })
        thread.append(.init(role: .user, text: "Hello", document: word))
        _ = try await client.replyWithDocuments(messages: thread, onStatus: { _ in }, onSources: { await recorder.set($0) }, onUpdate: { _ in })
        let request = await grounded.requests.last!
        try check(request.count == 1 && request[0].text.contains("Hello") && !request[0].text.contains("SECRET_OLD") && !request[0].text.contains("125 dollars"), "active-file isolation")
        try check(await recorder.sources.allSatisfy { $0.documentID == word.id }, "sources belong to active file")
        let calls = await grounded.requests.count
        _ = try await client.reply(messages: [.init(role: .user, text: "quasar", document: a)], onUpdate: { _ in })
        try check(await grounded.requests.count == calls, "no evidence avoids model call")
        try await rejectsAsync({ _ = try await client.reply(messages: [.init(role: .user, text: String(repeating: "x", count: 2001), document: a)], onUpdate: { _ in }) }, "oversized question")
        print("PASS ordinary chat forwarding, active-file switching, source ownership and no-match model bypass")

        let sessionURL = root.appendingPathComponent("chats.json")
        let session = TutorSession(client: client, storageURL: sessionURL)
        let first = session.selectedID
        session.attach(a); session.draft = "cancellation fee"
        session.newConversation(); let second = session.selectedID
        try check(first != second, "new chat overwrote attachment draft")
        session.attach(word)
        let restored = TutorSession(client: client, storageURL: sessionURL)
        try check(restored.pendingDocument == word, "attachment draft restore")
        restored.select(first)
        try check(restored.pendingDocument == a && restored.draft == "cancellation fee", "draft isolation")
        restored.send(); await restored.waitUntilIdle()
        try check(restored.pendingDocument == nil && restored.activeDocument == a && restored.messages.first?.document == a, "send attachment")
        let saved = TutorSession(client: client, storageURL: sessionURL)
        try check(saved.messages.last?.sources?.first?.documentID == a.id, "sources saved with reply before final save")
        saved.draft = String(repeating: "x", count: 2001); saved.send()
        try check(!saved.isResponding && saved.draft.count == 2001, "question validation preserves draft")
        saved.newConversation(); saved.attach(word); saved.send(); await saved.waitUntilIdle()
        try check(saved.messages.first?.text == "Give me an overview of this document." && saved.activeDocument == word, "attachment-only message")
        // Clearing context is a durable inference boundary, not deletion of displayed history.
        let leaving = TutorSession(client: client, storageURL: root.appendingPathComponent("leaving.json"))
        leaving.attach(word); leaving.draft = "Hello"; leaving.send(); await leaving.waitUntilIdle()
        let originalMessages = leaving.messages
        let originalActivity = leaving.current.updatedAt
        leaving.draft = "Keep this unfinished question"
        leaving.clearDocumentContext()
        try check(leaving.activeDocument == nil && leaving.pendingDocument == nil && leaving.canUndoDocumentContext, "clear did not leave context")
        try check(leaving.messages == originalMessages && leaving.current.updatedAt == originalActivity && leaving.draft == "Keep this unfinished question", "clear changed history, activity or draft")
        try check(try await store.read(word.id).reference == word, "clear deleted shared original")
        leaving.retry()
        try check(leaving.messages == originalMessages && !leaving.isResponding, "retry resurrected a cleared document turn")
        let leavingReopen = TutorSession(client: client, storageURL: root.appendingPathComponent("leaving.json"))
        try check(leavingReopen.activeDocument == nil && leavingReopen.messages == originalMessages && !leavingReopen.canUndoDocumentContext, "clear boundary did not survive relaunch")
        leaving.undoClearDocumentContext()
        try check(leaving.activeDocument == word && leaving.messages == originalMessages && !leaving.canUndoDocumentContext, "undo failed to restore active file")
        leaving.attach(a); leaving.clearDocumentContext(); leaving.undoClearDocumentContext()
        try check(leaving.pendingDocument == a && leaving.activeDocument == word, "undo lost pending replacement or previous active file")
        leaving.clearDocumentContext()
        let documentCallsBefore = await grounded.requests.count
        leaving.draft = String(repeating: "x", count: 2001); leaving.send(); await leaving.waitUntilIdle()
        let ordinaryAfterClear = await ordinary.requests.last!
        try check(ordinaryAfterClear.count == 1 && ordinaryAfterClear[0].text.utf8.count == 2001 && ordinaryAfterClear[0].document == nil,
                  "ordinary prompt retained old document turns or file question limit")
        try check(await grounded.requests.count == documentCallsBefore && !leaving.canUndoDocumentContext && leaving.activeDocument == nil,
                  "sending after clear reused document model path or retained stale undo")
        leaving.undoClearDocumentContext()
        try check(leaving.activeDocument == nil, "stale undo changed a later turn")
        leaving.attach(word); leaving.draft = "Hello"; leaving.send(); await leaving.waitUntilIdle()
        try check(leaving.activeDocument == word && leaving.messages.last?.sources?.first?.documentID == word.id, "reselecting did not resume document Q&A")
        leaving.clearDocumentContext(); let leavingID = leaving.selectedID
        leaving.newConversation(); leaving.undoClearDocumentContext()
        try check(leaving.activeDocument == nil && !leaving.canUndoDocumentContext, "undo crossed conversations")
        leaving.select(leavingID)
        try check(leaving.activeDocument == nil, "switching resurrected cleared file")
        let pendingOnly = TutorSession(client: client, storageURL: root.appendingPathComponent("pending-only.json"))
        pendingOnly.draft = "Ordinary earlier question"; pendingOnly.send(); await pendingOnly.waitUntilIdle()
        pendingOnly.attach(word); pendingOnly.clearDocumentContext()
        try check(pendingOnly.current.documentContextStartIndex == nil && pendingOnly.pendingDocument == nil, "unsent attachment cleared ordinary conversation context")
        pendingOnly.undoClearDocumentContext()
        try check(pendingOnly.pendingDocument == word && pendingOnly.activeDocument == nil, "undo did not restore unsent attachment")
        pendingOnly.clearDocumentContext(); pendingOnly.draft = "Ordinary followup"; pendingOnly.send(); await pendingOnly.waitUntilIdle()
        try check(await ordinary.requests.last?.count == 3, "removing unsent file lost ordinary-chat history")
        let malformedURL = root.appendingPathComponent("malformed-boundary.json")
        let invalidHistory = TutorConversation(messages: [.init(role: .user, text: "Hello", document: word)], documentContextStartIndex: -1)
        try JSONEncoder().encode([invalidHistory]).write(to: malformedURL)
        try check(TutorSession(client: client, storageURL: malformedURL).activeDocument == word, "invalid boundary did not recover")
        print("PASS clear/undo, preserved drafts/history/originals, relaunch, ordinary routing, reattach and boundary recovery")
        let json = "{\"id\":\"\(UUID().uuidString)\",\"role\":\"user\",\"text\":\"legacy\"}"
        try check(try JSONDecoder().decode(TutorMessage.self, from: Data(json.utf8)).document == nil, "old chat migration")
        try await store.remove(a.id)
        try await rejectsAsync({ _ = try await store.read(a.id) }, "deleted file")
        try check(saved.messages.last?.sources != nil, "deleting library file should not erase saved sources")
        print("PASS attachment drafts, thread switching, persisted sources, attachment-only send and legacy history")
        let late = LateDocumentTutor(sources: sources)
        let stopped = TutorSession(client: late, storageURL: root.appendingPathComponent("stopped.json"))
        stopped.attach(word); stopped.draft = "overview"; stopped.send()
        while !(await late.started) { await Task.yield() }
        stopped.newConversation()
        try await Task.sleep(for: .milliseconds(120))
        try check(stopped.messages.isEmpty && !stopped.isResponding, "late source/update contaminated new conversation")
        let lateClear = LateDocumentTutor(sources: sources)
        let clearWhileRunning = TutorSession(client: lateClear, storageURL: root.appendingPathComponent("clear-running.json"))
        clearWhileRunning.attach(word); clearWhileRunning.draft = "Hello"; clearWhileRunning.send()
        while !(await lateClear.started) { await Task.yield() }
        clearWhileRunning.draft = "Next draft"
        clearWhileRunning.clearDocumentContext()
        try await Task.sleep(for: .milliseconds(120))
        try check(!clearWhileRunning.isResponding && clearWhileRunning.activeDocument == nil && clearWhileRunning.messages.count == 1 &&
                  clearWhileRunning.draft == "Next draft" && clearWhileRunning.canUndoDocumentContext,
                  "clearing active response lost draft or accepted stale callbacks")
        clearWhileRunning.undoClearDocumentContext()
        try check(clearWhileRunning.activeDocument == word && !clearWhileRunning.isResponding, "undo resumed cancelled generation")
        print("PASS clear during generation stops response and rejects late document sources/updates")
        let quota = ChatDocumentStore(root: root.appendingPathComponent("quota"))
        for _ in 0..<DocumentLimits.libraryFiles { _ = try await quota.importFile(txt) }
        try await rejectsAsync({ _ = try await quota.importFile(txt) }, "recent file count quota")
        try check(await quota.recent().count == DocumentLimits.libraryFiles, "quota changed saved files")
        let large = ExtractedDocument(reference: reference(), sections: [.init(location: "Paragraph 1", text: String(repeating: "Recurring ordinary project notes. ", count: 1450) + " raretoken 902")])
        let clock = ContinuousClock(); let start = clock.now
        let largeSources = DocumentRetrieval.sources(document: large, question: "raretoken")
        try check(largeSources.contains { $0.text.contains("902") }, "long-file retrieval missed tail")
        print("HOST RETRIEVAL: \(large.sections[0].text.count) characters, \(start.duration(to: clock.now))")
        print("PASS stale sources after cancellation, library quota and long-file retrieval")
        print("PASS document chat suite")
    }
}
