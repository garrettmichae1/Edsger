import Foundation

private struct TestFailure: Error { let message: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(message: message) }
}

private struct ImmediateTutor: TutorCompleting {
    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        onUpdate("Saved answer"); return "Saved answer"
    }
}
private struct TestPlanner: MathPlanning {
    var plan: MathPlan = .notCalculation
    func mathPlan(messages: [TutorMessage]) async throws -> MathPlan { plan }
}
private struct TestCalculator: MathCalculating {
    func calculate(_ request: MathRequest) async throws -> MathCalculation {
        .init(ok: true, input: "2+2", latex: "4", exact: "4")
    }
}
// Only the default dependency is replaced. All session and routing code is production code.
enum SelectedChatClient {
    static let shared = CalculatingTutorClient(tutor: ImmediateTutor(), planner: TestPlanner(), calculator: TestCalculator())
}

private final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GenerationStatus] = []
    func append(_ value: GenerationStatus) { lock.withLock { stored.append(value) } }
    var values: [GenerationStatus] { lock.withLock { stored } }
}

private actor ControlledTutor: TutorCompleting {
    struct Request {
        let status: GenerationStatusHandler
        let update: @Sendable (String) -> Void
        let continuation: CheckedContinuation<String, any Error>
    }
    var requests: [Request] = []
    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try await reply(messages: messages, onStatus: { _ in }, onUpdate: onUpdate)
    }
    func reply(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
               onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(status: onStatus, update: onUpdate, continuation: continuation))
        }
    }
    func emit(_ index: Int, status: GenerationStatus, text: String? = nil) {
        requests[index].status(status)
        if let text { requests[index].update(text) }
    }
    func finish(_ index: Int) { requests[index].continuation.resume(returning: "Final answer") }
    func fail(_ index: Int) { requests[index].continuation.resume(throwing: TestFailure(message: "Failed")) }
}

@main private struct ChatExperienceTests {
    @MainActor static func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock().now < deadline else { throw TestFailure(message: "Timed out waiting for test state") }
            await Task.yield()
        }
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("conversations.json")
        let session = TutorSession(client: ImmediateTutor(), storageURL: url)
        let first = session.selectedID
        let originalHistory = try Data(contentsOf: url)
        session.draft = "Unsent α + β\nsecond line"
        session.newConversation()
        let second = session.selectedID
        try check(second != first, "New chat overwrote a draft-only conversation")
        session.draft = "Second draft"
        session.select(first)
        try check(session.draft == "Unsent α + β\nsecond line", "Switch lost first draft")
        session.select(second)
        try check(session.draft == "Second draft", "Switch lost second draft")
        let reopened = TutorSession(client: ImmediateTutor(), storageURL: url)
        try check(reopened.selectedID == second && reopened.draft == "Second draft", "Reopen lost active chat/draft")
        reopened.select(first)
        try check(reopened.draft == "Unsent α + β\nsecond line", "Reopen lost another chat's draft")
        print("PASS independent Unicode drafts, draft-only new chats, transitions, and reopen")

        reopened.draft = "A question"
        reopened.send(); await reopened.waitUntilIdle()
        try check(reopened.draft.isEmpty, "Send failed to clear only current draft")
        try check(reopened.draft(for: second) == "Second draft", "Send cleared another chat's draft")
        try check(reopened.messages.last?.text == "Saved answer" && reopened.generationStatus == nil, "Reply/status did not finish")
        reopened.draft = String(repeating: "x", count: 16001)
        reopened.send()
        try check(reopened.draft.count == 16001 && !reopened.isResponding, "Rejected question lost its draft")
        reopened.delete(first)
        let afterDelete = TutorSession(client: ImmediateTutor(), storageURL: url)
        try check(afterDelete.selectedID == second && afterDelete.draft == "Second draft", "Deleting chat lost surviving draft")
        try check(afterDelete.draft(for: first).isEmpty, "Deleted draft came back")
        print("PASS send, validation rejection, deletion, and surviving draft recovery")

        let debounceURL = root.appendingPathComponent("debounce.json")
        let debounced = TutorSession(client: ImmediateTutor(), storageURL: debounceURL)
        let beforeTyping = try Data(contentsOf: debounceURL)
        debounced.draft = "old"; debounced.draft = "latest"
        try await Task.sleep(for: .milliseconds(500))
        let debouncedReopen = TutorSession(client: ImmediateTutor(), storageURL: debounceURL)
        try check(debouncedReopen.draft == "latest", "Debounce failed to save latest draft")
        let afterTyping = try Data(contentsOf: debounceURL)
        try check(afterTyping == beforeTyping, "Typing rewrote full conversation history")
        debounced.draft = "inactive flush"; debounced.flushDrafts()
        try check(TutorSession(client: ImmediateTutor(), storageURL: debounceURL).draft == "inactive flush", "Lifecycle flush lost pending keystrokes")
        try check(!originalHistory.isEmpty, "Initial chat ID was not saved")
        print("PASS debounced draft-only writes and immediate lifecycle flush")

        let legacyURL = root.appendingPathComponent("legacy.json")
        let legacy = TutorConversation(messages: [.init(role: .user, text: "Existing question")])
        try JSONEncoder().encode([legacy]).write(to: legacyURL)
        let migrated = TutorSession(client: ImmediateTutor(), storageURL: legacyURL)
        try check(migrated.messages.first?.text == "Existing question" && migrated.draft.isEmpty, "Legacy history did not load")
        migrated.draft = "new draft"; migrated.flushDrafts()
        try check(TutorSession(client: ImmediateTutor(), storageURL: legacyURL).draft == "new draft", "Legacy chat cannot preserve drafts")
        print("PASS existing history compatibility")

        let retentionURL = root.appendingPathComponent("retention.json")
        var history = (0..<100).map { index in TutorConversation(messages: [.init(role: .user, text: "Chat \(index)")], updatedAt: Date(timeIntervalSince1970: Double(index))) }
        let oldest = history[0].id
        history.reverse()
        try JSONEncoder().encode(history).write(to: retentionURL)
        let retention = TutorSession(client: ImmediateTutor(), storageURL: retentionURL)
        retention.select(oldest); retention.draft = "Protect unfinished work"; retention.newConversation()
        try check(retention.conversations.count == 100 && retention.conversations.contains { $0.id == oldest }, "History pruning deleted unfinished work")
        try check(TutorSession(client: ImmediateTutor(), storageURL: retentionURL).draft(for: oldest) == "Protect unfinished work", "Pruned history lost protected draft")
        print("PASS history retention preserves active and unfinished chats")

        let pinsURL = root.appendingPathComponent("pins.json")
        let older = TutorConversation(messages: [.init(role: .user, text: "Favorite older chat")], updatedAt: Date(timeIntervalSince1970: 10))
        let newer = TutorConversation(messages: [.init(role: .user, text: "Recent chat")], updatedAt: Date(timeIntervalSince1970: 20))
        let another = TutorConversation(messages: [.init(role: .user, text: "Another favorite")], updatedAt: Date(timeIntervalSince1970: 15))
        let legacyPins = try JSONEncoder().encode([older, another, newer])
        try check(!String(decoding: legacyPins, as: UTF8.self).contains("pinnedAt"), "Fixture must represent pre-pin history")
        try legacyPins.write(to: pinsURL)
        let pins = TutorSession(client: ImmediateTutor(), storageURL: pinsURL)
        try check(pins.conversations.map(\.id) == [newer.id, another.id, older.id], "Legacy chats are not ordered by recency")
        pins.select(newer.id); pins.draft = "Keep this draft"
        pins.togglePin(older.id)
        try check(pins.conversations.first?.id == older.id && pins.conversations.first?.isPinned == true, "Pin did not move older chat to top")
        try check(pins.conversations.first?.updatedAt == older.updatedAt, "Pin changed conversation activity date")
        try check(pins.selectedID == newer.id && pins.draft == "Keep this draft", "Pin changed selected chat or draft")
        let pinsReopen = TutorSession(client: ImmediateTutor(), storageURL: pinsURL)
        try check(pinsReopen.conversations.first?.id == older.id && pinsReopen.conversations.first?.isPinned == true, "Pin did not survive reopening")
        pinsReopen.select(newer.id); pinsReopen.draft = "Update recent chat"; pinsReopen.send(); await pinsReopen.waitUntilIdle()
        try check(pinsReopen.conversations.first?.id == older.id, "New activity displaced a pinned favorite")
        pinsReopen.togglePin(older.id)
        try check(pinsReopen.conversations.first?.id == newer.id && !pinsReopen.conversations.contains(where: \.isPinned), "Unpin did not restore recency order")
        let afterUnpin = TutorSession(client: ImmediateTutor(), storageURL: pinsURL)
        try check(!afterUnpin.conversations.contains(where: \.isPinned), "Unpin did not persist")
        let unchanged = afterUnpin.conversations
        afterUnpin.togglePin(UUID())
        try check(afterUnpin.conversations == unchanged, "Unknown pin target changed history")
        print("PASS legacy pin compatibility, top placement, reopen, activity, unpin, and selection/draft preservation")

        let pinnedRetentionURL = root.appendingPathComponent("pinned-retention.json")
        var pinHistory = (0..<100).map { index in TutorConversation(messages: [.init(role: .user, text: "History \(index)")], updatedAt: Date(timeIntervalSince1970: Double(index))) }
        let oldestPinned = pinHistory[0].id
        let secondPinned = pinHistory[1].id
        pinHistory[0].pinnedAt = Date(timeIntervalSince1970: 100)
        pinHistory[1].pinnedAt = Date(timeIntervalSince1970: 101)
        try JSONEncoder().encode(pinHistory.reversed().map { $0 }).write(to: pinnedRetentionURL)
        let protectedPins = TutorSession(client: ImmediateTutor(), storageURL: pinnedRetentionURL)
        try check(Array(protectedPins.conversations.prefix(2)).map(\.id) == [secondPinned, oldestPinned], "Multiple pins did not retain stable pin order")
        protectedPins.newConversation()
        try check(protectedPins.conversations.count == 100 && protectedPins.conversations.filter(\.isPinned).count == 2, "History pruning discarded a pinned chat")
        protectedPins.select(secondPinned); protectedPins.draft = "Continue favorite"; protectedPins.send(); await protectedPins.waitUntilIdle()
        try check(Array(protectedPins.conversations.prefix(2)).map(\.id) == [secondPinned, oldestPinned], "Pinned order changed after generation")
        protectedPins.delete(secondPinned)
        let afterPinnedDelete = TutorSession(client: ImmediateTutor(), storageURL: pinnedRetentionURL)
        try check(afterPinnedDelete.conversations.first?.id == oldestPinned && !afterPinnedDelete.conversations.contains { $0.id == secondPinned }, "Deleting one pin damaged another or restored deleted chat")
        let emptyPinnedURL = root.appendingPathComponent("empty-pin.json")
        let emptyPinned = TutorSession(client: ImmediateTutor(), storageURL: emptyPinnedURL)
        let emptyPinnedID = emptyPinned.selectedID
        emptyPinned.togglePin(emptyPinnedID); emptyPinned.newConversation()
        try check(emptyPinned.selectedID != emptyPinnedID && emptyPinned.conversations.contains { $0.id == emptyPinnedID && $0.isPinned }, "New chat reused a pinned favorite")
        print("PASS multiple-pin order, protected retention, deletion, and pinned-empty chat preservation")

        let controlled = ControlledTutor()
        let live = TutorSession(client: controlled, storageURL: root.appendingPathComponent("live.json"))
        live.draft = "Question"; live.send()
        try check(live.generationStatus == .waiting, "Missing immediate waiting status")
        try await waitFor { await controlled.requests.count == 1 }
        await controlled.emit(0, status: .loadingModel)
        try await waitFor { live.generationStatus == .loadingModel }
        await controlled.emit(0, status: .generatingResponse, text: "Partial answer")
        try await waitFor { live.messages.last?.text == "Partial answer" }
        live.draft = "Draft typed while generating"
        live.stop()
        await controlled.emit(0, status: .loadingModel, text: "Stale answer")
        await controlled.finish(0)
        for _ in 0..<30 { await Task.yield() }
        try check(live.messages.last?.text == "Partial answer" && live.generationStatus == nil, "Cancelled callbacks modified stopped chat")
        try check(live.draft == "Draft typed while generating", "Stop lost next draft")
        live.newConversation(); live.draft = "New question"; live.send()
        try await waitFor { await controlled.requests.count == 2 }
        await controlled.emit(0, status: .calculating, text: "Old run")
        await controlled.emit(1, status: .preparingPrompt)
        try await waitFor { live.generationStatus == .preparingPrompt }
        try check(live.messages.last?.text == "", "Old run wrote into new conversation")
        await controlled.fail(1); await live.waitUntilIdle()
        try check(live.generationStatus == nil && !live.isResponding && live.errorMessage != nil, "Failure left generation status active")
        print("PASS live phases, partial stop, stale callbacks, new runs, and failure cleanup")

        let arithmeticStatuses = StatusRecorder()
        let math = CalculatingTutorClient(tutor: ImmediateTutor(), planner: TestPlanner(), calculator: TestCalculator())
        _ = try await math.reply(messages: [.init(role: .user, text: "2+2")], onStatus: { arithmeticStatuses.append($0) }) { _ in }
        try check(arithmeticStatuses.values == [.calculating], "Direct arithmetic reported unnecessary model phases")
        let explanationStatuses = StatusRecorder()
        let planned = CalculatingTutorClient(tutor: ImmediateTutor(), planner: TestPlanner(plan: .calculate(.init(operation: "solve", expression: "x=4"))), calculator: TestCalculator())
        _ = try await planned.reply(messages: [.init(role: .user, text: "Solve x=4")], onStatus: { explanationStatuses.append($0) }) { _ in }
        try check(explanationStatuses.values == [.planningCalculation, .calculating, .generatingResponse], "Math phase routing/order is wrong")
        print("PASS direct arithmetic and planned-calculation/explanation phase routing")

        var scrolling = TranscriptScrollState()
        scrolling.updateDistanceFromBottom(300) // Content grows before an automatic scroll happens.
        try check(scrolling.contentChanged(), "Answer growth broke following")
        scrolling.beginInteraction(); scrolling.updateDistanceFromBottom(250)
        try check(!scrolling.contentChanged(), "Follow fought a user gesture")
        scrolling.endInteraction()
        try check(!scrolling.contentChanged() && scrolling.hasUnreadContent, "Reading older messages did not pause following")
        scrolling.showLatest()
        try check(scrolling.contentChanged() && !scrolling.hasUnreadContent, "Explicit latest jump did not resume following")
        scrolling.beginInteraction(); scrolling.updateDistanceFromBottom(20); scrolling.endInteraction()
        try check(scrolling.shouldFollow, "Scrolling back near the bottom did not resume following")
        scrolling.beginInteraction()
        try check(!scrolling.contentChanged(), "Scrolling near bottom was interrupted")
        print("PASS scroll follow, gesture suppression, unread content, explicit jump, and return to bottom")
        print("All chat experience checks passed.")
    }
}
