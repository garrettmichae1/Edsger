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
    var modelCount = 0
    var pauseCompletion = false
    var completionStarted = false
    var completionPending: CheckedContinuation<Void, Never>?
    func configureCompletion(pause: Bool) { pauseCompletion = pause }
    func releaseCompletion() { completionPending?.resume(); completionPending = nil }
    var replies: [AgentCompletion] = []
    var requests: [Data] = []
    func enqueue(_ replies: [AgentCompletion]) { self.replies = replies }
    func configure(reject: Bool = false, pause: Bool = false) { rejectVerification = reject; pauseVerification = pause }
    func release() { pending?.resume(); pending = nil }
    func models(provider: BYOKProvider, key: String) async throws -> [BYOKModel] {
        modelCount += 1
        return [.init(id: "gpt-4.1-mini", name: "Mini")]
    }
    func verify(choice: BYOKChoice, key: String) async throws {
        started = true
        if pauseVerification { await withCheckedContinuation { pending = $0 } }
        if rejectVerification { throw BYOKError.providerCode("invalid_key") }
    }
    func complete(choice: BYOKChoice, key: String, messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion {
        completeCount += 1; requests.append(messagesJSON)
        completionStarted = true
        if pauseCompletion { await withCheckedContinuation { completionPending = $0 } }
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

    @Test func freeAccessCannotConfigureOrSelectPaidModels() async throws {
        let credentials = MemoryCredentials(), connection = FixtureConnection()
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection,
                              premiumAccess: { false }, premiumRevision: { 0 })
        await #expect(throws: BYOKError.premiumRequired) {
            _ = try await store.loadModels(provider: .openai, draftKey: secret, consent: true)
        }
        await #expect(throws: BYOKError.premiumRequired) {
            try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true)
        }
        store.selectChat(choice); store.selectAgentDefault(choice)
        store.selectAgent(choice, language: .python, project: "test")
        #expect(store.chatChoice == nil && store.agentDefault == nil)
        #expect(store.agentChoice(language: .python, project: "test") == nil)
        #expect(store.choices.isEmpty)
        #expect(await connection.modelCount == 0)
        #expect(!(await connection.started))
        #expect(try credentials.read(.openai) == nil)
        // Free local runs and explicit local selections remain available.
        try store.beginRun(); store.endRun(); store.selectChat(nil)
        #expect(store.canConfigure)
    }
    @Test func expiredMembershipKeepsKeysButUsesLocalAndBlocksBoundRequests() async throws {
        var paid = true
        let credentials = MemoryCredentials(), connection = FixtureConnection()
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection,
                              premiumAccess: { paid }, premiumRevision: { 0 })
        try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true)
        store.selectChat(choice); store.selectAgentDefault(choice)
        let bound = try store.client(for: choice)
        paid = false
        #expect(store.effectiveChatChoice == nil)
        #expect(store.agentChoice(language: .python, project: "test") == nil)
        #expect(store.chatChoice == choice && store.agentDefault == choice)
        #expect(try credentials.read(.openai) == secret)
        await #expect(throws: BYOKError.premiumRequired) {
            _ = try await bound.complete(messagesJSON: Data("[]".utf8), toolsJSON: Data("[]".utf8))
        }
        #expect(await connection.completeCount == 0)
        store.setConsent(false, provider: .openai)
        store.setConsent(true, provider: .openai)
        #expect(store.configurations["openai"]?.sharingConsent == false)
        try store.remove(.openai)
        #expect(try credentials.read(.openai) == nil)
    }
    @Test func lossOfProDuringVerificationCannotSaveCredentials() async throws {
        var paid = true
        let credentials = MemoryCredentials(), connection = FixtureConnection()
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection,
                              premiumAccess: { paid }, premiumRevision: { 0 })
        await connection.configure(pause: true)
        let task = Task { try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true) }
        while !(await connection.started) { await Task.yield() }
        paid = false
        await connection.release()
        await #expect(throws: BYOKError.premiumRequired) { try await task.value }
        #expect(try credentials.read(.openai) == nil)
        #expect(store.configurations.isEmpty)
    }
    @Test func revokedAccessCannotReleaseCloudToolsEvenAfterRestoration() async throws {
        var revision = 0
        let credentials = MemoryCredentials(), connection = FixtureConnection()
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection,
                              premiumAccess: { true }, premiumRevision: { revision })
        try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true)
        let bound = try store.client(for: choice)
        await connection.configureCompletion(pause: true)
        await connection.enqueue([.init(assistantText: "", toolCalls: [.init(id: "x", name: "write_file", argumentsJSON: "{}")])])
        let task = Task { try await bound.complete(messagesJSON: Data("[]".utf8), toolsJSON: Data("[]".utf8)) }
        while !(await connection.completionStarted) { await Task.yield() }
        revision += 1 // Entitlement changed while the provider was responding.
        await connection.releaseCompletion()
        await #expect(throws: BYOKError.premiumRequired) { _ = try await task.value }
        #expect(await connection.completeCount == 1)
    }
    @Test func membershipExpirationAndRevocationFailClosed() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(MembershipAccess.isActive(expiration: now.addingTimeInterval(1), revocation: nil, upgraded: false, now: now))
        #expect(!MembershipAccess.isActive(expiration: now, revocation: nil, upgraded: false, now: now))
        #expect(!MembershipAccess.isActive(expiration: nil, revocation: nil, upgraded: false, now: now))
        #expect(!MembershipAccess.isActive(expiration: now.addingTimeInterval(1), revocation: now, upgraded: false, now: now))
        #expect(!MembershipAccess.isActive(expiration: now.addingTimeInterval(1), revocation: nil, upgraded: true, now: now))
    }
    @Test func keysNeverAppearInPersistedMetadataAndProjectChoicesSurviveReload() async throws {
        let defaults = defaults(), credentials = MemoryCredentials(), connection = FixtureConnection()
        defer { for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("edsger.byok") { defaults.removeObject(forKey: key) } }
        let store = BYOKStore(defaults: defaults, credentials: credentials, connection: connection, premiumAccess: { true }, premiumRevision: { 0 })
        try await store.save(provider: .openai, draftKey: secret, modelID: choice.modelID, models: models, consent: true)
        store.selectChat(choice); store.selectAgentDefault(choice)
        store.selectAgent(nil, language: .python, project: "local-project")
        store.selectAgent(choice, language: .c, project: "cloud-project")
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("edsger.byok") {
            #expect(!(String(describing: value).contains(secret)))
            if let data = value as? Data { #expect(!String(decoding: data, as: UTF8.self).contains(secret)) }
        }
        let restored = BYOKStore(defaults: defaults, credentials: credentials, connection: connection, premiumAccess: { true }, premiumRevision: { 0 })
        #expect(restored.chatChoice == choice)
        #expect(restored.agentChoice(language: .python, project: "local-project") == nil)
        #expect(restored.agentChoice(language: .c, project: "cloud-project") == choice)
        #expect(restored.agentChoice(language: .lua, project: "new-project") == choice)
    }
    @Test func oneProviderCanOfferMultipleVerifiedModelsWithDistinctPickerIDs() async throws {
        let credentials = MemoryCredentials(), connection = FixtureConnection()
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection, premiumAccess: { true }, premiumRevision: { 0 })
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
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection, premiumAccess: { true }, premiumRevision: { 0 })
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
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection, premiumAccess: { true }, premiumRevision: { 0 })
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
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection, premiumAccess: { true }, premiumRevision: { 0 })
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
        let store = BYOKStore(defaults: defaults(), credentials: credentials, connection: connection, premiumAccess: { true }, premiumRevision: { 0 })
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
    @Test func bundledMathEngineEvaluatesDefiniteIntegralWithoutFFI() async throws {
        let bundle = Bundle.main.bundleURL
        let frameworks = bundle.appendingPathComponent("Frameworks")
        let names = try FileManager.default.contentsOfDirectory(atPath: frameworks.path)
        #expect(!names.contains { $0.hasPrefix("PythonModule--ctypes") })
        let request = MathRequest(operation: "integrate", expression: "x^2", lower: "0", upper: "1")
        let result = try await LocalMathCalculator.shared.calculate(request)
        #expect(result.ok, Comment(rawValue: result.error ?? "No successful math result"))
        #expect(result.exact == "1/3")
        let worked = try await LocalMathCalculator.shared.calculateIntegralWork(request)
        #expect(worked.ok)
        #expect(worked.exact == "1/3")
        #expect(worked.steps?.isEmpty == false)
    }

    @Test func providerAgentUsesScopedWorkspaceAndSymPyWithPairedResults() async throws {
        let credentials = MemoryCredentials(), connection = FixtureConnection(), defaults = defaults()
        let store = BYOKStore(defaults: defaults, credentials: credentials, connection: connection, premiumAccess: { true }, premiumRevision: { 0 })
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
    @Test func workspaceAgentToolsRejectExistingAndDanglingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("byok.symlinks." + UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.py")
        try "sentinel".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link.py"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("dangling.py"), withDestinationURL: root.appendingPathComponent("new.py"))
        let workspace = LocalCWorkspace(defaults: defaults(), directoryURL: project, language: .python)
        #expect(workspace.agentSafeRelativePath("link.py") == nil)
        #expect(workspace.agentSafeRelativePath("dangling.py") == nil)
        #expect(workspace.agentWriteFile("link.py", contents: "changed").hasPrefix("Rejected"))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "sentinel")
    }
    @Test func malformedProviderBatchCannotPartiallyEditAProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = MemoryCredentials(), connection = FixtureConnection(), defaults = defaults()
        let store = BYOKStore(defaults: defaults, credentials: credentials, connection: connection, premiumAccess: { true }, premiumRevision: { 0 })
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

    private func httpClient() -> BYOKProviderClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return BYOKProviderClient(configuration: configuration)
    }
    private var userMessages: Data { Data(#"[{"role":"user","content":"Help"}]"#.utf8) }
    private var readTool: [[String: Any]] { [["type": "function", "function": ["name": "read_file", "description": "Read a file", "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]]]] }
    private nonisolated static func wireBody(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try BYOKNativeCodec.parseObject(data) }
        guard let stream = request.httpBodyStream else { throw BYOKError.invalidResponse }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw BYOKError.invalidResponse }
            if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return try BYOKNativeCodec.parseObject(data)
    }
    @Test func transportUsesOnlyPersonalKeyAndDecodesNativeCalls() async throws {
        let expectedKey = secret
        FixtureURLProtocol.fixture.set { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + expectedKey)
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            #expect(request.value(forHTTPHeaderField: "X-LilC-Device") == nil)
            #expect(request.value(forHTTPHeaderField: "X-LilC-GitHub") == nil)
            return (200, Data(#"{"status":"completed","output":[{"type":"function_call","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"main.py\"}"}]}"#.utf8))
        }
        let result = try await httpClient().complete(choice: choice, key: secret, messagesJSON: userMessages, toolsJSON: JSONSerialization.data(withJSONObject: readTool))
        #expect(result.toolCalls[0].name == "read_file")
        let saved = try BYOKNativeCodec.parseObject(Data(result.continuationJSON!.utf8))
        #expect(saved["provider"] as? String == "openai")
    }
    @Test func claudeTransportUsesNativeHostAndCredentialHeaders() async throws {
        let expectedKey = secret
        FixtureURLProtocol.fixture.set { request in
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == expectedKey)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            return (200, Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}"#.utf8))
        }
        let result = try await httpClient().complete(choice: .init(provider: .anthropic, modelID: "claude-opus-5-5"), key: secret, messagesJSON: userMessages, toolsJSON: Data("[]".utf8))
        #expect(result.assistantText == "Done")
    }
    @Test func transportSanitizesErrorsAndRejectsInvalidResponses() async throws {
        FixtureURLProtocol.fixture.set { _ in (401, Data(#"{"error":{"message":"fixture-personal-key-123456789"}}"#.utf8)) }
        await #expect(throws: BYOKError.providerCode("invalid_key")) { _ = try await httpClient().models(provider: .openai, key: secret) }
        FixtureURLProtocol.fixture.set { _ in (200, Data("malformed response".utf8)) }
        await #expect(throws: BYOKError.invalidResponse) { _ = try await httpClient().models(provider: .openai, key: secret) }
        FixtureURLProtocol.fixture.set { _ in (200, Data(#"{"status":"completed","output":[]}"#.utf8)) }
        await #expect(throws: BYOKError.invalidResponse) { _ = try await httpClient().complete(choice: choice, key: secret, messagesJSON: userMessages, toolsJSON: Data("[]".utf8)) }
    }
    @Test func transportRejectsUnsupportedModelsAndCancelledTasksBeforeSending() async throws {
        FixtureURLProtocol.fixture.set { _ in Issue.record("No HTTP request should be made"); return (500, Data()) }
        for model in ["https://evil.invalid", "gpt-4o-realtime-preview", "tts-1"] {
            await #expect(throws: BYOKError.providerCode("unsupported_model")) { _ = try await httpClient().complete(choice: .init(provider: .openai, modelID: model), key: secret, messagesJSON: userMessages, toolsJSON: Data("[]".utf8)) }
        }
        let cancelled = Task { try Task.checkCancellation(); _ = try await httpClient().models(provider: .openai, key: secret) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
    @Test func modelCatalogUsesDirectGETFiltersAndPaginates() async throws {
        FixtureURLProtocol.fixture.set { request in
            #expect(request.httpMethod == "GET")
            if request.url?.query?.contains("after_id") == true {
                #expect(request.url?.host == "api.anthropic.com")
                return (200, Data(#"{"data":[{"id":"claude-haiku-4-5","display_name":"Haiku"}],"has_more":false}"#.utf8))
            }
            return (200, Data(#"{"data":[{"id":"claude-opus-5-5","display_name":"Opus"},{"id":"embedding-v1"}],"has_more":true,"last_id":"claude-opus-5-5"}"#.utf8))
        }
        let models = try await httpClient().models(provider: .anthropic, key: secret)
        #expect(models.map(\.name) == ["Haiku", "Opus"])
    }
    @Test func bothProvidersVerifyWithAnActualNativeToolRoundTrip() async throws {
        for provider in BYOKProvider.allCases {
            FixtureURLProtocol.fixture.set { request in
                let body = try! Self.wireBody(request)
                if provider == .openai {
                    let input = try! BYOKNativeCodec.objects(body["input"], maximum: 10)
                    if input.last?["type"] as? String == "function_call_output" {
                        #expect(input.last?["output"] as? String == "OK")
                        return (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#.utf8))
                    }
                    #expect(try! BYOKNativeCodec.object(body["tool_choice"])["name"] as? String == "edsger_connection_check")
                    return (200, Data(#"{"status":"completed","output":[{"type":"function_call","call_id":"probe","name":"edsger_connection_check","arguments":"{\"value\":\"OK\"}"}]}"#.utf8))
                }
                #expect(try! BYOKNativeCodec.object(body["tool_choice"])["type"] as? String == "auto")
                let turns = try! BYOKNativeCodec.objects(body["messages"], maximum: 10)
                if turns.count > 1 {
                    let content = try! BYOKNativeCodec.objects(turns.last?["content"], maximum: 10)
                    #expect(content[0]["tool_use_id"] as? String == "probe")
                    #expect(content[0]["content"] as? String == "OK")
                    return (200, Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"OK"}]}"#.utf8))
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
    private var mobileSnapshot: [String: Any] {
        ["remainingNanoUSD": "4999000000", "limitNanoUSD": "5000000000",
         "renewsAt": 2_000_000_000_000 as Int64, "available": true, "rateCard": "fixture-v1"]
    }
    private func mobileFixture() -> MobileAgentClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        return MobileAgentClient(configuration: config, authorize: { "apple-signed-fixture-proof" })
    }
    @Test func membershipBudgetsAreExactAndDoNotGrantLegacySubscription() {
        #expect(EdsgerMembership.pro.monthlyUSD == 10)
        #expect(EdsgerMembership.pro.allowanceNanoUSD == 5_000_000_000)
        #expect(EdsgerMembership.plus.monthlyUSD == 25)
        #expect(EdsgerMembership.plus.allowanceNanoUSD == 15_000_000_000)
        #expect(EdsgerMembership(rawValue: "lilc.agent.monthly") == nil)
        #expect(MobileAgentConfiguration.isEnabled == false)
    }
    @Test func flagshipEndpointIsExactHTTPSAndRejectsWorkersWildcardsOrURLCredentials() {
        for raw in ["http://api.lilc.app/v1/mobile-agent", "https://attacker.workers.dev/v1/mobile-agent", "https://api.lilc.app.attacker.example/v1/mobile-agent", "https://key@api.lilc.app/v1/mobile-agent", "https://api.lilc.app:444/v1/mobile-agent", "https://api.lilc.app/v1/mobile-agent?redirect=bad"] {
            #expect(throws: MobileAgentError.unavailable) { try MobileAgentEndpoint.validate(URL(string: raw)!, allowedHosts: ["api.lilc.app"]) }
        }
    }
    @Test func flagshipUsesOnlyAppleProofAndReturnsValidatedFileTools() async throws {
        let reply: [String: Any] = ["allowance": mobileSnapshot, "completion": ["assistantText": "Creating file", "toolCalls": [["id": "file1", "name": "write_file", "argumentsJSON": #"{"path":"hello.py","contents":"print(1)"}"#]]]]
        let data = try JSONSerialization.data(withJSONObject: reply)
        FixtureURLProtocol.fixture.set { request in
            #expect(request.url?.absoluteString == "https://api.lilc.app/v1/mobile-agent/completions")
            #expect(request.value(forHTTPHeaderField: "X-Apple-Transaction-JWS") == "apple-signed-fixture-proof")
            #expect(request.value(forHTTPHeaderField: "X-Edsger-AI-Consent") == "v1")
            #expect(UUID(uuidString: request.value(forHTTPHeaderField: "X-Edsger-Request-ID") ?? "") != nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "X-LilC-GitHub") == nil)
            return (200, data)
        }
        let result = try await mobileFixture().complete(messagesJSON: Data(#"[{"role":"user","content":"Create a file"}]"#.utf8), toolsJSON: JSONSerialization.data(withJSONObject: AgentToolRegistry.specifications))
        #expect(result.toolCalls.first?.name == "write_file")
        #expect(result.continuationJSON == nil)
    }
    @Test func flagshipRejectsEntireBatchWhenAnyToolEscapesWorkspace() async throws {
        let reply: [String: Any] = ["allowance": mobileSnapshot, "completion": ["assistantText": "", "toolCalls": [
            ["id": "ok", "name": "write_file", "argumentsJSON": #"{"path":"ok.py","contents":"print(1)"}"#],
            ["id": "bad", "name": "write_file", "argumentsJSON": #"{"path":"../secret.py","contents":"bad"}"#]]]]
        let data = try JSONSerialization.data(withJSONObject: reply)
        FixtureURLProtocol.fixture.set { _ in (200, data) }
        await #expect(throws: (any Error).self) {
            _ = try await mobileFixture().complete(messagesJSON: Data(#"[{"role":"user","content":"Create a file"}]"#.utf8), toolsJSON: JSONSerialization.data(withJSONObject: AgentToolRegistry.specifications))
        }
    }
    @Test func flagshipQuotaAndRateLimitsAreDistinctFromInvalidResponses() async throws {
        for (code, failure) in [("allowance_exhausted", MobileAgentError.exhausted), ("rate_limited", MobileAgentError.rateLimited), ("membership_required", MobileAgentError.membershipRequired)] {
            let data = try JSONSerialization.data(withJSONObject: ["error": code, "allowance": mobileSnapshot])
            FixtureURLProtocol.fixture.set { _ in (429, data) }
            await #expect(throws: failure) {
                _ = try await mobileFixture().complete(messagesJSON: Data(#"[{"role":"user","content":"Hi"}]"#.utf8), toolsJSON: Data("[]".utf8))
            }
        }
        #expect(MobileAgentError.exhausted.usesLocalNext)
        #expect(!MobileAgentError.invalidResponse.usesLocalNext)
    }
    @Test func flagshipNeverSendsWithoutFreshAuthorization() async throws {
        FixtureURLProtocol.fixture.set { _ in Issue.record("No unauthorized request may be sent"); return (500, Data()) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureURLProtocol.self]
        let client = MobileAgentClient(configuration: config, authorize: { throw MobileAgentError.consentRequired })
        await #expect(throws: MobileAgentError.consentRequired) {
            _ = try await client.complete(messagesJSON: Data(#"[{"role":"user","content":"Hi"}]"#.utf8), toolsJSON: Data("[]".utf8))
        }
    }

}
