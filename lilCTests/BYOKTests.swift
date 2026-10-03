import Foundation
import Testing
#if canImport(BYOKCore)
@testable import BYOKCore
#else
@testable import lilC
#endif

private final class MemoryCredentials: ProviderCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BYOKProvider: String] = [:]
    func read(_ provider: BYOKProvider) throws -> String? { lock.withLock { values[provider] } }
    func save(_ key: String, for provider: BYOKProvider) throws { lock.withLock { values[provider] = key } }
    func remove(_ provider: BYOKProvider) throws { _ = lock.withLock { values.removeValue(forKey: provider) } }
}
private actor FixtureConnection: BYOKConnecting {
    var rejectVerification = false
    var pauseVerification = false
    var started = false
    var pending: CheckedContinuation<Void, Never>?
    var completeCount = 0
    var replies: [AgentCompletion] = []
    var requests: [Data] = []
    func enqueue(_ replies: [AgentCompletion]) { self.replies = replies }
    func configure(reject: Bool = false, pause: Bool = false) { rejectVerification = reject; pauseVerification = pause }
    func release() { pending?.resume(); pending = nil }
    func models(provider: BYOKProvider, key: String) async throws -> [BYOKModel] { [.init(id: "gpt-4.1-mini", name: "Mini")] }
    func verify(choice: BYOKChoice, key: String) async throws {
        started = true
        if pauseVerification { await withCheckedContinuation { pending = $0 } }
        if rejectVerification { throw BYOKError.relayCode("invalid_key") }
    }
    func complete(choice: BYOKChoice, key: String, messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion {
        completeCount += 1; requests.append(messagesJSON)
        return replies.isEmpty ? .init(assistantText: "Done", toolCalls: []) : replies.removeFirst()
    }
}

private final class HTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var responder: (@Sendable (URLRequest) -> (Int, Data))?
    func set(_ responder: @escaping @Sendable (URLRequest) -> (Int, Data)) { lock.withLock { self.responder = responder } }
    func response(_ request: URLRequest) -> (Int, Data) { lock.withLock { responder!(request) } }
}
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = HTTPFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.fixture.response(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor
struct BYOKTests {
    private let secret = "fixture-personal-key-123456789"
    private let models = [BYOKModel(id: "gpt-4.1-mini", name: "Mini")]
    private var choice: BYOKChoice { .init(provider: .openai, modelID: models[0].id) }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "byok.tests." + UUID().uuidString)! }

    @Test func keysNeverAppearInPersistedMetadataAndProjectChoicesSurviveReload() async throws {
        let defaults = defaults(), credentials = MemoryCredentials(), connection = FixtureConnection()
        defer { for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("edsger.byok") { defaults.removeObject(forKey: key) } }
        let store = BYOKStore(defaults: defaults, credentials: credentials, connection: connection)
        try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true)
        store.selectChat(choice); store.selectAgentDefault(choice)
        store.selectAgent(nil, language: .python, project: "local-project")
        store.selectAgent(choice, language: .c, project: "cloud-project")
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("edsger.byok") {
            #expect(!(String(describing: value).contains(secret)))
            if let data = value as? Data { #expect(!String(decoding: data, as: UTF8.self).contains(secret)) }
        }
        let restored = BYOKStore(defaults: defaults, credentials: credentials, connection: connection)
        #expect(restored.chatChoice == choice)
        #expect(restored.agentChoice(language: .python, project: "local-project") == nil)
        #expect(restored.agentChoice(language: .c, project: "cloud-project") == choice)
        #expect(restored.agentChoice(language: .lua, project: "new-project") == choice)
    }
    @Test func oneProviderCanOfferMultipleVerifiedModelsWithDistinctPickerIDs() async throws {
        let credentials = MemoryCredentials(), connection = FixtureConnection()
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection)
        let catalog = models + [.init(id: "gpt-4.1", name: "Standard")]
        try await store.save(provider: .openai, draftKey: secret, modelID: catalog[0].id, models: catalog, consent: true)
        #expect(store.choices.count == 1)
        try await store.save(provider: .openai, draftKey: "", modelID: catalog[1].id, models: catalog, consent: true)
        #expect(store.choices.count == 2)
        #expect(Set(store.choices.map(\.id)).count == 2)
        try await store.save(provider: .openai, draftKey: "replacement-personal-key-123456", modelID: catalog[1].id, models: catalog, consent: true)
        #expect(store.choices == [.init(provider: .openai, modelID: catalog[1].id)])
    }
    @Test func failedReplacementPreservesWorkingCredentialAndModel() async throws {
        let credentials = MemoryCredentials(), connection = FixtureConnection()
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection)
        try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true)
        await connection.configure(reject: true)
        await #expect(throws: BYOKError.relayCode("invalid_key")) {
            try await store.save(provider: .openai, draftKey: "rejected-replacement-key-12345", modelID: choice.modelID, models: models, consent: true)
        }
        #expect(try credentials.read(.openai) == secret)
        #expect(store.choices == [choice])
        #expect(store.canConfigure)
    }
    @Test func consentCannotBeRestoredByAnInFlightVerification() async throws {
        let credentials = MemoryCredentials(), connection = FixtureConnection()
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection)
        await connection.configure(pause: true)
        let saving = Task { try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true) }
        while !(await connection.started) { await Task.yield() }
        store.setConsent(false, provider: .openai)
        await connection.release()
        await #expect(throws: BYOKError.consentRequired) { try await saving.value }
        #expect(try credentials.read(.openai) == nil)
        #expect(store.configurations.isEmpty)
    }
    @Test func boundClientChecksConsentForEveryRequestAndRemovalDoesNotFallback() async throws {
        let credentials = MemoryCredentials(), connection = FixtureConnection()
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection)
        try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true)
        store.selectChat(choice)
        let client = try store.client(for: choice)
        store.setConsent(false, provider: .openai)
        await #expect(throws: BYOKError.consentRequired) { _ = try await client.complete(messagesJSON: Data("[]".utf8), toolsJSON: Data("[]".utf8)) }
        #expect(await connection.completeCount == 0)
        try store.remove(.openai)
        #expect(store.chatChoice == choice)
        #expect(throws: BYOKError.missingKey) { _ = try store.client(for: choice) }
    }
    @Test func runningTasksLockConfigurationButAllowConsentWithdrawal() async throws {
        let connection = FixtureConnection(), credentials = MemoryCredentials()
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection)
        try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true)
        store.selectChat(choice); try store.beginRun()
        #expect(!store.canConfigure)
        store.selectChat(nil); #expect(store.chatChoice == choice)
        #expect(throws: BYOKError.busy) { try store.remove(.openai) }
        store.setConsent(false, provider: .openai)
        #expect(throws: BYOKError.consentRequired) { try store.requireConsent(.openai) }
        store.endRun(); #expect(store.canConfigure)
    }
    @Test func oldHistoriesDecodeAndInterruptedToolsBecomeHistoricalText() throws {
        let old = AgentChatMessage(role: .assistant, text: "Earlier answer")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object.removeValue(forKey: "toolCalls"); object.removeValue(forKey: "toolCallID"); object.removeValue(forKey: "continuationJSON")
        let decoded = try JSONDecoder().decode(AgentChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.toolCalls == nil)
        let call = AgentToolCall(id: "call", name: "write_file", argumentsJSON: "{\"path\":\"main.py\",\"contents\":\"x\"}")
        let interrupted = AgentWireHistory.messages([.init(role: .user, text: "Edit"), .init(role: .assistant, text: "", toolCalls: [call]), .init(role: .user, text: "Continue")])
        #expect(!interrupted.contains { $0["tool_calls"] != nil || $0["role"] as? String == "tool" })
        let paired = AgentWireHistory.messages([.init(role: .user, text: "Edit"), .init(role: .assistant, text: "", toolCalls: [call]), .init(role: .tool, text: "Updated", toolName: call.name, toolCallID: call.id)])
        #expect(paired[1]["tool_calls"] != nil); #expect(paired[2]["tool_call_id"] as? String == "call")
    }
    @Test func historicalClaudeThinkingIsRemovedButLiveToolContinuationsStayIntact() throws {
        let call = AgentToolCall(id: "call", name: "read_file", argumentsJSON: #"{"path":"main.py"}"#)
        let saved: [String: Any] = ["provider": "anthropic", "model": "claude-opus-5-5", "items": [
            ["type": "thinking", "thinking": "", "signature": "old-prefix-signature"],
            ["type": "redacted_thinking", "data": "old-prefix-data"],
            ["type": "tool_use", "id": call.id, "name": call.name, "input": ["path": "main.py"]]
        ]]
        let native = String(decoding: try JSONSerialization.data(withJSONObject: saved), as: UTF8.self)
        let history = AgentWireHistory.messages([.init(role: .user, text: "Read"), .init(role: .assistant, text: "", toolCalls: [call], continuationJSON: native), .init(role: .tool, text: "contents", toolCallID: call.id)])
        let historical = try #require(history[1]["edsger_continuation"] as? String)
        #expect(!historical.contains("old-prefix-signature") && !historical.contains("old-prefix-data"))
        #expect(historical.contains("tool_use"))
        #expect(AgentWireHistory.assistant(text: "", calls: [call], continuation: native)["edsger_continuation"] as? String == native)
    }
    @Test func invalidToolArgumentsCannotReachTheWorkspace() throws {
        for args in ["{}", "{\"path\":\"../outside.py\",\"contents\":\"x\"}", "{\"path\":\"main.py\",\"contents\":42}", "{\"path\":\"main.py\",\"contents\":\"x\",\"extra\":\"x\"}"] {
            #expect(throws: (any Error).self) { _ = try AgentToolRegistry.validatedArguments(.init(id: "x", name: "write_file", argumentsJSON: args)) }
        }
        #expect(throws: (any Error).self) { _ = try AgentToolRegistry.validatedArguments(.init(id: "x", name: "execute_shell", argumentsJSON: "{}")) }
        let request = MathRequest(operation: "evaluate", expression: "1/3+1/6")
        let args = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(try AgentToolRegistry.validatedArguments(.init(id: "math", name: "calculate_math", argumentsJSON: args))["expression"] as? String == "1/3+1/6")
    }

    #if !canImport(BYOKCore)
    @Test func providerAgentUsesScopedWorkspaceAndSymPyWithPairedResults() async throws {
        let credentials = MemoryCredentials(), connection = FixtureConnection(), defaults = defaults()
        let store = BYOKStore(defaults: defaults, credentials: credentials, connection: connection)
        try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = LocalCWorkspace(defaults: defaults, directoryURL: root)
        _ = workspace.agentWriteFile("project/main.c", contents: "#include <stdio.h>\nint main(void) { puts(\"old\"); return 0; }\n")
        func call(_ id: String, _ name: String, _ arguments: [String: String]) throws -> AgentToolCall {
            .init(id: id, name: name, argumentsJSON: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
        }
        await connection.enqueue([
            .init(assistantText: "Edit", toolCalls: [try call("edit", "replace_text", ["path": "main.c", "old_text": "old", "new_text": "BYOK works"])]),
            .init(assistantText: "Create", toolCalls: [try call("create", "write_file", ["path": "helper.h", "contents": "int helper(void);\n"])]),
            .init(assistantText: "Run", toolCalls: [try call("run", "run_file", ["path": "main.c"])]),
            .init(assistantText: "Calculate", toolCalls: [try call("math", "calculate_math", ["operation": "evaluate", "expression": "1/3+1/6", "variable": "x", "lower": "", "upper": ""])]),
            .init(assistantText: "Done", toolCalls: [])
        ])
        let session = AgentSession(workspace: workspace, settings: AgentSettingsStore(defaults: defaults), client: try store.client(for: choice), savesHistory: false)
        session.draft = "Edit the program, create a header, run it and calculate 1/3+1/6."
        session.send(); await session.waitUntilIdle()
        #expect(session.statusLine == "Ready")
        #expect(workspace.agentReadFile("project/main.c")?.contains("BYOK works") == true)
        #expect(workspace.agentReadFile("project/helper.h") == "int helper(void);\n")
        #expect(session.messages.contains { $0.toolCallID == "run" && $0.text.contains("BYOK works") })
        #expect(session.messages.contains { $0.toolCallID == "math" && $0.text.contains("Calculated on device") })
        #expect(session.restorePoints.count == 1)
        let requests = await connection.requests
        let final = try JSONSerialization.jsonObject(with: requests.last!) as! [[String: Any]]
        #expect(Set(final.filter { $0["role"] as? String == "tool" }.compactMap { $0["tool_call_id"] as? String }) == Set(["edit", "create", "run", "math"]))
    }
    @Test func malformedProviderBatchCannotPartiallyEditAProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = MemoryCredentials(), connection = FixtureConnection(), defaults = defaults()
        let store = BYOKStore(defaults: defaults, credentials: credentials, connection: connection)
        try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true)
        let workspace = LocalCWorkspace(defaults: defaults, directoryURL: root)
        let original = "int main(void) { return 0; }\n"
        _ = workspace.agentWriteFile("project/main.c", contents: original)
        await connection.enqueue([.init(assistantText: "Edit", toolCalls: [
            .init(id: "valid", name: "write_file", argumentsJSON: #"{"path":"main.c","contents":"int main(void) { return 9; }"}"#),
            .init(id: "invalid", name: "execute_shell", argumentsJSON: "{}")
        ])])
        let session = AgentSession(workspace: workspace, settings: AgentSettingsStore(defaults: defaults), client: try store.client(for: choice), savesHistory: false)
        session.draft = "Edit main.c"; session.send(); await session.waitUntilIdle()
        #expect(workspace.agentReadFile("project/main.c") == original)
        #expect(session.restorePoints.isEmpty)
    }
    #endif

    private func httpClient(baseURL: URL = URL(string: "https://api.lilc.app/v1/byok")!) -> BYOKRelayClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return BYOKRelayClient(baseURL: baseURL, configuration: configuration)
    }
    @Test func transportUsesOnlyPersonalKeyAndDecodesNativeCalls() async throws {
        let expectedKey = secret
        FixtureURLProtocol.fixture.set { request in
            #expect(request.url?.absoluteString == "https://api.lilc.app/v1/byok/openai/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + expectedKey)
            #expect(request.value(forHTTPHeaderField: "X-LilC-Device") == nil)
            #expect(request.value(forHTTPHeaderField: "X-LilC-GitHub") == nil)
            return (200, Data(#"{"assistantText":"","toolCalls":[{"id":"call_1","name":"read_file","argumentsJSON":"{\"path\":\"main.py\"}"}],"continuationJSON":"opaque"}"#.utf8))
        }
        let result = try await httpClient().complete(choice: choice, key: secret, messagesJSON: Data("[]".utf8), toolsJSON: Data("[]".utf8))
        #expect(result.toolCalls[0].name == "read_file")
        #expect(result.continuationJSON == "opaque")
    }
    @Test func transportSanitizesErrorsAndRejectsInvalidResponses() async throws {
        FixtureURLProtocol.fixture.set { _ in (401, Data(#"{"error":"invalid_key","private":"fixture-personal-key-123456789"}"#.utf8)) }
        await #expect(throws: BYOKError.relayCode("invalid_key")) { _ = try await httpClient().models(provider: .openai, key: secret) }
        FixtureURLProtocol.fixture.set { _ in (200, Data("malformed response".utf8)) }
        await #expect(throws: BYOKError.invalidResponse) { _ = try await httpClient().models(provider: .openai, key: secret) }
        FixtureURLProtocol.fixture.set { _ in (200, Data(#"{"assistantText":"","toolCalls":[]}"#.utf8)) }
        await #expect(throws: BYOKError.invalidResponse) { _ = try await httpClient().complete(choice: choice, key: secret, messagesJSON: Data("[]".utf8), toolsJSON: Data("[]".utf8)) }
    }
    @Test func transportRejectsInsecureURLsAndCancelledTasksBeforeSending() async throws {
        FixtureURLProtocol.fixture.set { _ in Issue.record("No HTTP request should be made"); return (500, Data()) }
        for raw in ["http://api.lilc.app/v1/byok", "https://user:pass@api.lilc.app/v1/byok", "https://api.lilc.app/v1/byok?secret=x"] {
            await #expect(throws: BYOKError.relayUnavailable) { _ = try await httpClient(baseURL: URL(string: raw)!).models(provider: .openai, key: secret) }
        }
        let cancelled = Task { try Task.checkCancellation(); _ = try await httpClient().models(provider: .openai, key: secret) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
    @Test func keyInputRejectsControlCharactersAndWhitespace() {
        for secret in ["short", "secret with spaces-123456", "secret-key\nembedded-123456", "secret-key-😄-123456"] {
            #expect(throws: BYOKError.invalidKey) { _ = try BYOKSecretValidation.clean(secret) }
        }
    }
}
