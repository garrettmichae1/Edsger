import Foundation

private final class MobileAgentNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct MobileAgentClient: AgentCompleting {
    private let session: URLSession
    private let baseURL: URL
    private let allowedHosts: [String]
    private let authorize: @Sendable () async throws -> String
    private let didUpdate: @Sendable (MobileAgentAllowance?, MobileAgentError?) async -> Void
    init(baseURL: URL = MobileAgentConfiguration.baseURL, allowedHosts: [String] = MobileAgentConfiguration.allowedHosts,
         configuration: URLSessionConfiguration? = nil, authorize: @escaping @Sendable () async throws -> String,
         didUpdate: @escaping @Sendable (MobileAgentAllowance?, MobileAgentError?) async -> Void = { _, _ in }) {
        self.baseURL = baseURL; self.allowedHosts = allowedHosts; self.authorize = authorize; self.didUpdate = didUpdate
        let config = configuration ?? .ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 150
        session = URLSession(configuration: config, delegate: MobileAgentNoRedirect(), delegateQueue: nil)
    }
    func allowance() async throws -> MobileAgentAllowance {
        let root = try await request(action: "allowance", body: nil)
        return try decodeAllowance(root["allowance"])
    }
    func complete(messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion {
        guard messagesJSON.count + toolsJSON.count <= 384 * 1024 else { throw MobileAgentError.invalidResponse }
        let messages = try BYOKNativeCodec.parseObjects(messagesJSON, maximum: 180)
        let tools = try BYOKNativeCodec.parseObjects(toolsJSON, maximum: 32)
        let root = try await request(action: "completions", body: ["messages": messages, "tools": tools])
        let completion = try BYOKNativeCodec.object(root["completion"])
        let text = try BYOKNativeCodec.string(completion["assistantText"], maximum: 180_000, allowEmpty: true)
        let rawCalls = try BYOKNativeCodec.objects(completion["toolCalls"], maximum: 32)
        let allowed = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        var ids = Set<String>()
        let calls = try rawCalls.map { raw -> AgentToolCall in
            let id = try BYOKNativeCodec.string(raw["id"], maximum: 200)
            let name = try BYOKNativeCodec.string(raw["name"], maximum: 100)
            let args = try BYOKNativeCodec.string(raw["argumentsJSON"], maximum: 65_536)
            guard ids.insert(id).inserted, allowed.contains(name) else { throw MobileAgentError.invalidResponse }
            let call = AgentToolCall(id: id, name: name, argumentsJSON: args)
            _ = try AgentToolRegistry.validatedArguments(call)
            return call
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !calls.isEmpty else { throw MobileAgentError.invalidResponse }
        return AgentCompletion(assistantText: text, toolCalls: calls)
    }
    private func decodeAllowance(_ raw: Any?) throws -> MobileAgentAllowance {
        guard let raw, JSONSerialization.isValidJSONObject(raw),
              let value = try? JSONDecoder().decode(MobileAgentAllowance.self, from: JSONSerialization.data(withJSONObject: raw)), value.isValid else { throw MobileAgentError.invalidResponse }
        return value
    }
    private func request(action: String, body: [String: Any]?) async throws -> [String: Any] {
        try Task.checkCancellation()
        try MobileAgentEndpoint.validate(baseURL, allowedHosts: allowedHosts)
        let proof = try await authorize()
        var request = URLRequest(url: baseURL.appendingPathComponent(action))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(proof, forHTTPHeaderField: "X-Apple-Transaction-JWS")
        if let body {
            request.setValue("v1", forHTTPHeaderField: "X-Edsger-AI-Consent")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Edsger-Request-ID")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard request.httpBody!.count <= 384 * 1024 else { throw MobileAgentError.invalidResponse }
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw MobileAgentError.unavailable }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1024 * 1024 else { throw MobileAgentError.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            let root = try BYOKNativeCodec.parseObject(data)
            let snapshot = root["allowance"].flatMap { try? decodeAllowance($0) }
            if !(200..<300).contains(http.statusCode) {
                let failure: MobileAgentError
                switch root["error"] as? String {
                case "allowance_exhausted": failure = .exhausted
                case "rate_limited": failure = .rateLimited
                case "consent_required": failure = .consentRequired
                case "membership_required", "stale_membership": failure = .membershipRequired
                case "busy", "duplicate_request": failure = .busy
                default: failure = .unavailable
                }
                await didUpdate(snapshot, failure)
                throw failure
            }
            _ = try await authorize() // Consent/entitlement can change while awaiting the response.
            guard let snapshot else { throw MobileAgentError.invalidResponse }
            await didUpdate(snapshot, nil)
            return root
        } catch is CancellationError { throw CancellationError() }
        catch let error as MobileAgentError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw MobileAgentError.unavailable
        }
    }
}
