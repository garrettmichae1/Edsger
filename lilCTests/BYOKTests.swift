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
        if rejectVerification { throw BYOKError.providerCode("invalid_key") }
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
        await #expect(throws: BYOKError.providerCode("invalid_key")) {
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
        await #expect(throws: BYOKError.consentRequired) { _ = try await client.complete(messagesJSON: Data("[]"…4850 tokens truncated…":"OK"}]}"#.utf8))
                }
                return (200, Data(#"{"stop_reason":"tool_use","content":[{"type":"thinking","thinking":"","signature":"signed"},{"type":"tool_use","id":"probe","name":"edsger_connection_check","input":{"value":"OK"}}]}"#.utf8))
            }
            try await httpClient().verify(choice: .init(provider: provider, modelID: provider == .openai ? "gpt-4.1-mini" : "claude-opus-5-5"), key: secret)
        }
    }
    @Test func verificationRejectsModelsThatSkipTheTool() async throws {
        FixtureURLProtocol.fixture.set { _ in (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#.utf8)) }
        await #expect(throws: BYOKError.providerCode("tool_test_failed")) { try await httpClient().verify(choice: choice, key: secret) }
    }
    @Test func transportBoundsBodiesAndResponsesAndDoesNotFollowRedirects() async throws {
        FixtureURLProtocol.fixture.set { _ in Issue.record("Oversized input must not request HTTP"); return (500, Data()) }
        await #expect(throws: BYOKError.providerCode("payload_too_large")) { _ = try await httpClient().complete(choice: choice, key: secret, messagesJSON: Data(repeating: 32, count: 385 * 1024), toolsJSON: Data("[]".utf8)) }
        FixtureURLProtocol.fixture.set { _ in (200, Data(repeating: 32, count: 1024 * 1024 + 1)) }
        await #expect(throws: BYOKError.invalidResponse) { _ = try await httpClient().models(provider: .openai, key: secret) }
        FixtureURLProtocol.fixture.set { _ in (302, Data()) }
        await #expect(throws: BYOKError.providerCode("provider_unavailable")) { _ = try await httpClient().models(provider: .openai, key: secret) }
    }
    @Test func nativeRequestsPreserveToolPairsAndReasoningAcrossBothProviders() throws {
        let call = AgentToolCall(id: "call", name: "read_file", argumentsJSON: #"{"path":"main.py"}"#)
        for provider in BYOKProvider.allCases {
            let selected = BYOKChoice(provider: provider, modelID: provider == .openai ? "gpt-4.1-mini" : "claude-opus-5-5")
            let items: [[String: Any]] = provider == .openai ? [["type": "reasoning", "encrypted_content": "sealed"], ["type": "function_call", "call_id": "call", "name": "read_file", "arguments": call.argumentsJSON]] : [["type": "thinking", "thinking": "", "signature": "signed"], ["type": "tool_use", "id": "call", "name": "read_file", "input": ["path": "main.py"]]]
            let saved = String(decoding: try JSONSerialization.data(withJSONObject: ["provider": provider.rawValue, "model": selected.modelID, "items": items]), as: UTF8.self)
            let messages: [[String: Any]] = [["role": "system", "content": "Rules"], ["role": "user", "content": "Help"], AgentWireHistory.assistant(text: "", calls: [call], continuation: saved), ["role": "tool", "tool_call_id": "call", "content": "source"]]
            let body = try BYOKNativeCodec.request(choice: selected, messages: messages, tools: readTool)
            if provider == .openai {
                #expect(body["store"] as? Bool == false)
                #expect(body["parallel_tool_calls"] as? Bool == false)
                let input = try BYOKNativeCodec.objects(body["input"], maximum: 10)
                #expect(input[1]["encrypted_content"] as? String == "sealed")
                #expect(input.last?["call_id"] as? String == "call")
            } else {
                let turns = try BYOKNativeCodec.objects(body["messages"], maximum: 10)
                #expect(try BYOKNativeCodec.objects(turns[1]["content"], maximum: 10)[0]["signature"] as? String == "signed")
                #expect(try BYOKNativeCodec.objects(turns[2]["content"], maximum: 10)[0]["tool_use_id"] as? String == "call")
                #expect(try BYOKNativeCodec.object(body["tool_choice"])["type"] as? String == "auto")
            }
        }
    }
    @Test func malformedHistoriesAndNativeOverridesFailBeforeNetwork() throws {
        let call = AgentToolCall(id: "call", name: "read_file", argumentsJSON: #"{"path":"main.py"}"#)
        let user: [String: Any] = ["role": "user", "content": "Help"]
        let assistant = AgentWireHistory.assistant(text: "", calls: [call], continuation: nil)
        for history in [[user, assistant], [user, ["role": "tool", "tool_call_id": "orphan", "content": "source"]], [user, assistant, user]] {
            #expect(throws: BYOKError.invalidResponse) { _ = try BYOKNativeCodec.request(choice: choice, messages: history, tools: readTool) }
        }
        let saved = #"{"provider":"openai","model":"gpt-4.1-mini","items":[{"type":"function_call","call_id":"call","name":"read_file","arguments":"{\"path\":\"other.py\"}"}]}"#
        let invalid = AgentWireHistory.assistant(text: "", calls: [call], continuation: saved)
        #expect(throws: BYOKError.invalidResponse) { _ = try BYOKNativeCodec.request(choice: choice, messages: [user, invalid, ["role": "tool", "tool_call_id": "call", "content": "source"]], tools: readTool) }
    }
    @Test func outputRejectsTruncationUnknownToolsAndDuplicateCalls() throws {
        #expect(throws: BYOKError.providerCode("incomplete_response")) { _ = try BYOKNativeCodec.completion(["status": "incomplete", "output": []], choice: choice, tools: readTool) }
        let unknown: [String: Any] = ["type": "function_call", "call_id": "one", "name": "unknown", "arguments": "{}"]
        #expect(throws: BYOKError.invalidResponse) { _ = try BYOKNativeCodec.completion(["status": "completed", "output": [unknown]], choice: choice, tools: readTool) }
        let call: [String: Any] = ["type": "function_call", "call_id": "one", "name": "read_file", "arguments": "{}"]
        #expect(throws: BYOKError.invalidResponse) { _ = try BYOKNativeCodec.completion(["status": "completed", "output": [call, call]], choice: choice, tools: readTool) }
    }
    @Test func providerBillingErrorsAreSanitizedAndDistinctFromTrafficLimits() throws {
        let billing = Data(#"{"error":{"code":"credit_balance_exhausted","message":"private"}}"#.utf8)
        #expect(BYOKNativeCodec.failure(provider: .openai, status: 429, data: billing) == .providerCode("insufficient_credit"))
        let spend = Data(#"{"error":{"code":"project_spend_limit_exceeded"}}"#.utf8)
        #expect(BYOKNativeCodec.failure(provider: .openai, status: 429, data: spend) == .providerCode("provider_spend_limit"))
        let claude = Data(#"{"error":{"message":"Your credit balance is too low to access the API."}}"#.utf8)
        #expect(BYOKNativeCodec.failure(provider: .anthropic, status: 400, data: claude) == .providerCode("insufficient_credit"))
        #expect(BYOKNativeCodec.failure(provider: .openai, status: 429, data: Data()) == .providerCode("provider_rate_limit"))
    }
    @Test func runtimeGuidesCoverAllFourRuntimesAndRejectUnknownTopics() throws {
        let runtimes = ["c": "PicoC", "python": "CPython", "javascript": "JavaScriptCore", "lua": "Lua 5.5.1"]
        for (language, runtime) in runtimes {
            #expect(AgentRuntimeDocumentation.read(language: language, topic: "overview")?.contains(runtime) == true)
            for topic in AgentRuntimeDocumentation.topics {
                #expect((AgentRuntimeDocumentation.read(language: language, topic: topic)?.utf8.count ?? 0) > 0)
                #expect((AgentRuntimeDocumentation.read(language: language, topic: topic)?.utf8.count ?? 9999) < 3000)
            }
        }
        #expect(AgentRuntimeDocumentation.read(language: "shell", topic: "overview") == nil)
        #expect(AgentRuntimeDocumentation.read(language: "python", topic: "../../private") == nil)
        let valid = AgentToolCall(id: "guide", name: "read_runtime_guide", argumentsJSON: #"{"topic":"modules"}"#)
        #expect(try AgentToolRegistry.validatedArguments(valid)["topic"] as? String == "modules")
        #expect(throws: BYOKError.invalidResponse) { _ = try AgentToolRegistry.validatedArguments(.init(id: "guide", name: "read_runtime_guide", argumentsJSON: #"{"topic":"unknown"}"#)) }
    }
    @Test func keyInputRejectsControlCharactersAndWhitespace() {
        for secret in ["short", "secret with spaces-123456", "secret-key\nembedded-123456", "secret-key-😄-123456"] {
            #expect(throws: BYOKError.invalidKey) { _ = try BYOKSecretValidation.clean(secret) }
        }
    }
}
