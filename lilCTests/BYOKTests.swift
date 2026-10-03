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
    func configure(reject: Bool = false, pause: Bool = false) { rejectVerification = reject; pauseVerification = pause }
    func release() { pending?.resume(); pending = nil }
    func models(provider: BYOKProvider, key: String) async throws -> [BYOKModel] { [.init(id: "gpt-4.1-mini", name: "Mini")] }
    func verify(choice: BYOKChoice, key: String) async throws {
        started = true
        if pauseVerification { await withCheckedContinuation { pending = $0 } }
        if rejectVerification { throw BYOKError.relayCode("invalid_key") }
    }
    func complete(choice: BYOKChoice, key: String, messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion {
        completeCount += 1
        return .init(assistantText: "Done", toolCalls: [])
    }
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
        #expect(throws: BYOKError.consentRequired) { _ = try store.client(for: choice) }
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
    @Test func invalidToolArgumentsCannotReachTheWorkspace() throws {
        for args in ["{}", "{\"path\":\"../outside.py\",\"contents\":\"x\"}", "{\"path\":\"main.py\",\"contents\":42}", "{\"path\":\"main.py\",\"contents\":\"x\",\"extra\":\"x\"}"] {
            #expect(throws: (any Error).self) { _ = try AgentToolRegistry.validatedArguments(.init(id: "x", name: "write_file", argumentsJSON: args)) }
        }
        #expect(throws: (any Error).self) { _ = try AgentToolRegistry.validatedArguments(.init(id: "x", name: "execute_shell", argumentsJSON: "{}")) }
        let request = MathRequest(operation: "evaluate", expression: "1/3+1/6")
        let args = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(try AgentToolRegistry.validatedArguments(.init(id: "math", name: "calculate_math", argumentsJSON: args))["expression"] as? String == "1/3+1/6")
    }
    @Test func keyInputRejectsControlCharactersAndWhitespace() {
        for secret in ["short", "secret with spaces-123456", "secret-key\nembedded-123456", "secret-key-😄-123456"] {
            #expect(throws: BYOKError.invalidKey) { _ = try BYOKSecretValidation.clean(secret) }
        }
    }
}
