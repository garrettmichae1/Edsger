import Foundation

enum BYOKRelayConfig {
    // Build-time configuration only. Never accept a key-bearing URL from user
    // preferences, provider output, deep links, or redirects.
    static let baseURL = URL(string: "https://api.lilc.app/v1/byok")!
}

private final class BYOKNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

protocol BYOKConnecting: Sendable {
    func models(provider: BYOKProvider, key: String) async throws -> [BYOKModel]
    func verify(choice: BYOKChoice, key: String) async throws
    func complete(choice: BYOKChoice, key: String, messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion
}

struct BYOKRelayClient: BYOKConnecting {
    private let session: URLSession
    private let baseURL: URL
    init(baseURL: URL = BYOKRelayConfig.baseURL, configuration: URLSessionConfiguration? = nil) {
        self.baseURL = baseURL
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 135; config.timeoutIntervalForResource = 150
        self.session = URLSession(configuration: config, delegate: BYOKNoRedirectDelegate(), delegateQueue: nil)
    }
    func models(provider: BYOKProvider, key: String) async throws -> [BYOKModel] {
        struct Catalog: Decodable { let models: [BYOKModel] }
        let data = try await request(provider: provider, key: key, action: "models", body: [:])
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { throw BYOKError.invalidResponse }
        return catalog.models
    }
    func verify(choice: BYOKChoice, key: String) async throws {
        struct Verification: Decodable { let ok: Bool }
        let data = try await request(provider: choice.provider, key: key, action: "verify", body: ["model": choice.modelID])
        guard let result = try? JSONDecoder().decode(Verification.self, from: data), result.ok else { throw BYOKError.invalidResponse }
    }
    func complete(choice: BYOKChoice, key: String, messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion {
        let messages = try JSONSerialization.jsonObject(with: messagesJSON), tools = try JSONSerialization.jsonObject(with: toolsJSON)
        let data = try await request(provider: choice.provider, key: key, action: "completions", body: ["model": choice.modelID, "messages": messages, "tools": tools])
        struct Result: Decodable {
            let assistantText: String
            let toolCalls: [AgentToolCall]
            let continuationJSON: String?
        }
        guard let result = try? JSONDecoder().decode(Result.self, from: data), result.toolCalls.count <= 8,
              Set(result.toolCalls.map(\.id)).count == result.toolCalls.count,
              !result.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !result.toolCalls.isEmpty else { throw BYOKError.invalidResponse }
        return .init(assistantText: result.assistantText, toolCalls: result.toolCalls, continuationJSON: result.continuationJSON)
    }
    private func request(provider: BYOKProvider, key: String, action: String, body: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw BYOKError.relayUnavailable }
        var request = URLRequest(url: baseURL.appending(path: provider.rawValue).appending(path: action))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + (try BYOKSecretValidation.clean(key)), forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard (request.httpBody?.count ?? 0) <= 384 * 1024 else { throw BYOKError.relayCode("payload_too_large") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw BYOKError.relayUnavailable }
            var data = Data()
            for try await byte in bytes {
                if data.count >= 1024 * 1024 { throw BYOKError.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode) else {
                struct Failure: Decodable { let error: String }
                let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "provider_unavailable"
                throw BYOKError.relayCode(code)
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as BYOKError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            // URLSession diagnostics and response bodies never enter UI/log/history.
            throw BYOKError.relayUnavailable
        }
    }
}

struct BYOKAgentClient: AgentCompleting {
    let choice: BYOKChoice
    let key: String
    let connection: any BYOKConnecting
    let authorize: @Sendable () async throws -> Void
    func complete(messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion {
        try Task.checkCancellation()
        try await authorize()
        return try await connection.complete(choice: choice, key: key, messagesJSON: messagesJSON, toolsJSON: toolsJSON)
    }
    func complete(messagesJSON: Data, toolsJSON: Data, onStatus: @escaping GenerationStatusHandler) async throws -> AgentCompletion {
        onStatus(.generatingResponse)
        return try await complete(messagesJSON: messagesJSON, toolsJSON: toolsJSON)
    }
}

struct BYOKChatClient: MathExplanationCompleting, MathPlanning {
    let agent: BYOKAgentClient
    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try await reply(messages: messages, onStatus: { _ in }, onUpdate: onUpdate)
    }
    func reply(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler, onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        // Keep the app's tutor/document/math instructions, but describe cloud
        // inference accurately. No project-writing tools are granted to Chat.
        let instructions = TutorPrompt.instructions.replacingOccurrences(of: "offline academic tutor", with: "academic tutor").replacingOccurrences(of: "You run entirely on the device, without internet browsing or current information.", with: "Your responses are generated by the selected cloud model. You have no internet browsing tools or access to current information.")
        let text = try await generate(instructions: instructions, messages: messages, onStatus: onStatus)
        onUpdate(text); return text
    }
    func explainCalculation(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler, onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try await reply(messages: messages, onStatus: onStatus, onUpdate: onUpdate)
    }
    func mathPlan(messages: [TutorMessage]) async throws -> MathPlan {
        try await mathPlan(messages: messages, onStatus: { _ in })
    }
    func mathPlan(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler) async throws -> MathPlan {
        let text = try await generate(instructions: MathPlannerPrompt.instructions, messages: Array(messages.suffix(6)), onStatus: onStatus)
        return try MathPlan.parse(Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }
    private func generate(instructions: String, messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler) async throws -> String {
        var wire: [[String: Any]] = [["role": "system", "content": instructions]]
        wire += messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let result = try await agent.complete(messagesJSON: JSONSerialization.data(withJSONObject: wire), toolsJSON: Data("[]".utf8), onStatus: onStatus)
        guard result.toolCalls.isEmpty else { throw BYOKError.invalidResponse }
        return result.assistantText
    }
}
