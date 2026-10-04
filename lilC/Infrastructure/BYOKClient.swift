import Foundation

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

/// Personal BYOK only. No developer secret, configurable gateway or app relay.
struct BYOKProviderClient: BYOKConnecting {
    private let session: URLSession
    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 150
        session = URLSession(configuration: config, delegate: BYOKNoRedirectDelegate(), delegateQueue: nil)
    }
    func models(provider: BYOKProvider, key: String) async throws -> [BYOKModel] {
        var found: [String: BYOKModel] = [:]
        var after: String?
        for page in 0..<10 {
            var path = "/models"
            if provider == .anthropic {
                path += "?limit=100"
                if let after { path += "&after_id=" + after }
            }
            let root = try await request(provider: provider, key: key, path: path, body: nil)
            for item in try BYOKNativeCodec.objects(root["data"], maximum: 1000) {
                let id = try BYOKNativeCodec.model(item["id"], provider: provider, requireSupported: false)
                if BYOKNativeCodec.supports(id, provider: provider) {
                    let name = try BYOKNativeCodec.string(item["display_name"] ?? id, maximum: 200)
                    found[id] = .init(id: id, name: name)
                }
            }
            if provider != .anthropic || root["has_more"] as? Bool != true { break }
            after = try BYOKNativeCodec.model(root["last_id"], provider: provider, requireSupported: false)
            guard page < 9 else { throw BYOKError.invalidResponse }
        }
        return found.values.sorted { $0.name < $1.name }
    }
    func verify(choice: BYOKChoice, key: String) async throws {
        let name = "edsger_connection_check"
        let tools: [[String: Any]] = [["type": "function", "function": ["name": name, "description": "Non-mutating connection test. Pass value OK.", "parameters": ["type": "object", "properties": ["value": ["type": "string", "enum": ["OK"]]], "required": ["value"], "additionalProperties": false]]]]
        var messages: [[String: Any]] = [["role": "user", "content": "Call edsger_connection_check with value OK, then acknowledge its result in one word."]]
        let first = try await complete(choice: choice, key: key, messages: messages, tools: tools, forcedTool: name)
        guard first.toolCalls.count == 1, let call = first.toolCalls.first, call.name == name,
              try BYOKNativeCodec.parseObject(Data(call.argumentsJSON.utf8))["value"] as? String == "OK" else { throw BYOKError.providerCode("tool_test_failed") }
        messages.append(AgentWireHistory.assistant(text: first.assistantText, calls: [call], continuation: first.continuationJSON))
        messages.append(["role": "tool", "tool_call_id": call.id, "content": "OK"])
        try Task.checkCancellation()
        let final = try await complete(choice: choice, key: key, messages: messages, tools: tools)
        guard final.toolCalls.isEmpty, !final.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BYOKError.providerCode("tool_test_failed") }
    }
    func complete(choice: BYOKChoice, key: String, messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion {
        guard messagesJSON.count + toolsJSON.count <= 384 * 1024 else { throw BYOKError.providerCode("payload_too_large") }
        let messages = try BYOKNativeCodec.parseObjects(messagesJSON, maximum: 180)
        let tools = try BYOKNativeCodec.parseObjects(toolsJSON, maximum: 32)
        return try await complete(choice: choice, key: key, messages: messages, tools: tools)
    }
    private func complete(choice: BYOKChoice, key: String, messages: [[String: Any]], tools: [[String: Any]], forcedTool: String? = nil) async throws -> AgentCompletion {
        let body = try BYOKNativeCodec.request(choice: choice, messages: messages, tools: tools, forcedTool: forcedTool)
        let root = try await request(provider: choice.provider, key: key, path: choice.provider.completionPath, body: body)
        return try BYOKNativeCodec.completion(root, choice: choice, tools: tools)
    }
    private func request(provider: BYOKProvider, key: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
        try Task.checkCancellation()
        let base = provider.apiBaseURL
        // All paths are generated internally; provider output contributes only validated model IDs.
        guard let url = URL(string: base + path), url.scheme == "https", url.user == nil, url.password == nil,
              url.host == (provider == .openai ? "api.openai.com" : "api.anthropic.com") else { throw BYOKError.providerUnavailable }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let secret = try BYOKSecretValidation.clean(key)
        if provider == .openai { request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization") }
        else {
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard request.httpBody!.count <= 384 * 1024 else { throw BYOKError.providerCode("payload_too_large") }
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw BYOKError.providerUnavailable }
            let succeeded = (200..<300).contains(response.statusCode)
            let limit = succeeded ? 1024 * 1024 : 16_384
            var data = Data()
            for try await byte in bytes {
                if data.count >= limit {
                    if !succeeded { throw BYOKNativeCodec.failure(provider: provider, status: response.statusCode, data: Data()) }
                    throw BYOKError.invalidResponse
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard succeeded else { throw BYOKNativeCodec.failure(provider: provider, status: response.statusCode, data: data) }
            return try BYOKNativeCodec.parseObject(data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as BYOKError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            // Never surface raw URLSession diagnostics, provider messages or request bodies.
            throw BYOKError.providerUnavailable
        }
    }
}

/// Native protocol adapters shared by catalog, verification, Chat and IDE.
/// Provider continuation is data, never an executable tool or endpoint override.
enum BYOKNativeCodec {
    static func object(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw BYOKError.invalidResponse }; return value
    }
    static func objects(_ value: Any?, maximum: Int) throws -> [[String: Any]] {
        guard let value = value as? [[String: Any]], value.count <= maximum else { throw BYOKError.invalidResponse }; return value
    }
    static func string(_ value: Any?, maximum: Int, allowEmpty: Bool = false) throws -> String {
        guard let value = value as? String, value.utf8.count <= maximum, allowEmpty || !value.isEmpty else { throw BYOKError.invalidResponse }; return value
    }
    static func parseObject(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { throw BYOKError.invalidResponse }; return try object(value)
    }
    static func parseObjects(_ data: Data, maximum: Int) throws -> [[String: Any]] {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { throw BYOKError.invalidResponse }; return try objects(value, maximum: maximum)
    }
    static func supports(_ id: String, provider: BYOKProvider) -> Bool {
        if provider == .anthropic { return id.range(of: "^claude-(sonnet|opus|haiku|fable|mythos|3|4|5)([-.]|$)", options: .regularExpression) != nil }
        return id.range(of: "^(gpt-(4o|4\\.1|5|6)([-.]|$)|o[134]([-]|$))", options: .regularExpression) != nil &&
            id.range(of: "audio|realtime|transcribe|tts|search|image|deep-research|chat-latest", options: .regularExpression) == nil
    }
    static func model(_ value: Any?, provider: BYOKProvider, requireSupported: Bool = true) throws -> String {
        let id = try string(value, maximum: 160)
        guard id.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil,
              !requireSupported || supports(id, provider: provider) else { throw BYOKError.providerCode("unsupported_model") }; return id
    }
    private static func native(_ message: [String: Any], choice: BYOKChoice) throws -> [[String: Any]]? {
        guard let raw = message["edsger_continuation"] else { return nil }
        let saved = try parseObject(Data(try string(raw, maximum: 180_000).utf8))
        guard saved["provider"] as? String == choice.provider.rawValue, saved["model"] as? String == choice.modelID else { return nil }
        let items = try objects(saved["items"], maximum: 64)
        let allowed = choice.provider == .openai ? ["message", "reasoning", "function_call"] : ["text", "tool_use", "thinking", "redacted_thinking"]
        guard items.allSatisfy({ allowed.contains($0["type"] as? String ?? "") }) else { throw BYOKError.invalidResponse }
        let calls = items.filter { $0["type"] as? String == (choice.provider == .openai ? "function_call" : "tool_use") }
        let expected = try objects(message["tool_calls"] ?? [], maximum: 8)
        guard calls.count == expected.count else { throw BYOKError.invalidResponse }
        for (call, canonical) in zip(calls, expected) {
            let fn = try object(canonical["function"])
            let args = try parseObject(Data(try string(fn["arguments"], maximum: 65_536).utf8))
            let nativeArgs = choice.provider == .openai ? try parseObject(Data(try string(call["arguments"], maximum: 65_536).utf8)) : try object(call["input"])
            guard call[choice.provider == .openai ? "call_id" : "id"] as? String == canonical["id"] as? String,
                  call["name"] as? String == fn["name"] as? String,
                  NSDictionary(dictionary: args).isEqual(to: nativeArgs) else { throw BYOKError.invalidResponse }
        }
        return items
    }
    static func request(choice: BYOKChoice, messages: [[String: Any]], tools: [[String: Any]], forcedTool: String? = nil) throws -> [String: Any] {
        _ = try model(choice.modelID, provider: choice.provider)
        guard messages.count <= 180, tools.count <= 32 else { throw BYOKError.invalidResponse }
        var toolNames = Set<String>()
        for tool in tools {
            let fn = try object(tool["function"]), name = try string(fn["name"], maximum: 64)
            guard tool["type"] as? String == "function", name.range(of: "^[a-zA-Z0-9_]+$", options: .regularExpression) != nil,
                  toolNames.insert(name).inserted, try object(fn["parameters"])["type"] as? String == "object" else { throw BYOKError.invalidResponse }
            _ = try string(fn["description"] ?? "", maximum: 4000, allowEmpty: true)
        }
        var pending = Set<String>(), seen = Set<String>(), hasUser = false
        for message in messages {
            let role = try string(message["role"], maximum: 16)
            guard ["system", "user", "assistant", "tool"].contains(role), pending.isEmpty || role == "tool" else { throw BYOKError.invalidResponse }
            _ = try string(message["content"] ?? "", maximum: 180_000, allowEmpty: true)
            if role == "user" { hasUser = true }
            if let raw = message["tool_calls"] {
                guard role == "assistant" else { throw BYOKError.invalidResponse }
                for call in try objects(raw, maximum: 8) {
                    let fn = try object(call["function"]), id = try string(call["id"], maximum: 200)
                    guard call["type"] as? String == "function", seen.insert(id).inserted else { throw BYOKError.invalidResponse }
                    _ = try string(fn["name"], maximum: 64)
                    _ = try parseObject(Data(try string(fn["arguments"], maximum: 65_536).utf8))
                    pending.insert(id)
                }
            }
            if role == "tool" { guard pending.remove(try string(message["tool_call_id"], maximum: 200)) != nil else { throw BYOKError.invalidResponse } }
            if message["edsger_continuation"] != nil && role != "assistant" { throw BYOKError.invalidResponse }
        }
        guard pending.isEmpty, hasUser else { throw BYOKError.invalidResponse }
        let system = messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }.joined(separator: "\n\n")
        if choice.provider == .openai {
            var input: [[String: Any]] = []
            for message in messages {
                let role = message["role"] as! String
                if role == "system" { continue }
                if role == "tool" { input.append(["type": "function_call_output", "call_id": message["tool_call_id"]!, "output": message["content"] ?? ""]); continue }
                if let items = try native(message, choice: choice) { input += items; continue }
                if let text = message["content"] as? String, !text.isEmpty { input.append(["role": role, "content": text]) }
                for call in try objects(message["tool_calls"] ?? [], maximum: 8) {
                    let fn = try object(call["function"])
                    input.append(["type": "function_call", "call_id": call["id"]!, "name": fn["name"]!, "arguments": fn["arguments"]!])
                }
            }
            var body: [String: Any] = ["model": choice.modelID, "instructions": system, "input": input, "store": false, "include": ["reasoning.encrypted_content"], "max_output_tokens": 8192]
            if !tools.isEmpty {
                body["tools"] = try tools.map { tool -> [String: Any] in var fn = try object(tool["function"]); fn["type"] = "function"; fn["strict"] = false; return fn }
                body["parallel_tool_calls"] = false
                body["tool_choice"] = forcedTool.map { ["type": "function", "name": $0] as Any } ?? "auto"
            }
            return body
        }
        var turns: [[String: Any]] = []
        for message in messages {
            let role = message["role"] as! String
            if role == "system" { continue }
            let targetRole = role == "tool" ? "user" : role
            var content: [[String: Any]] = []
            if role == "tool" { content.append(["type": "tool_result", "tool_use_id": message["tool_call_id"]!, "content": message["content"] ?? ""]) }
            else if let items = try native(message, choice: choice) { content += items }
            else {
                if let text = message["content"] as? String, !text.isEmpty { content.append(["type": "text", "text": text]) }
                for call in try objects(message["tool_calls"] ?? [], maximum: 8) {
                    let fn = try object(call["function"])
                    content.append(["type": "tool_use", "id": call["id"]!, "name": fn["name"]!, "input": try parseObject(Data((fn["arguments"] as! String).utf8))])
                }
            }
            if content.isEmpty { continue }
            if turns.last?["role"] as? String == targetRole { turns[turns.count - 1]["content"] = (turns.last?["content"] as! [[String: Any]]) + content }
            else { turns.append(["role": targetRole, "content": content]) }
        }
        let legacy = choice.modelID.range(of: "^claude-3-(haiku|opus|sonnet)-", options: .regularExpression) != nil
        var body: [String: Any] = ["model": choice.modelID, "system": system, "messages": turns, "max_tokens": legacy ? 4096 : 8192]
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in let fn = try object(tool["function"]); return ["name": fn["name"]!, "description": fn["description"] ?? "", "input_schema": fn["parameters"]!] }
            body["tool_choice"] = ["type": "auto", "disable_parallel_tool_use": true]
        }
        return body
    }
    static func completion(_ root: [String: Any], choice: BYOKChoice, tools: [[String: Any]]) throws -> AgentCompletion {
        guard choice.provider == .openai ? root["status"] as? String == "completed" : ["end_turn", "tool_use", "stop_sequence"].contains(root["stop_reason"] as? String ?? "") else { throw BYOKError.providerCode("incomplete_response") }
        let items = try objects(root[choice.provider == .openai ? "output" : "content"], maximum: 64)
        let allowed = choice.provider == .openai ? ["message", "reasoning", "function_call"] : ["text", "tool_use", "thinking", "redacted_thinking"]
        var text = "", calls: [AgentToolCall] = []
        for item in items {
            let type = try string(item["type"], maximum: 64)
            guard allowed.contains(type) else { throw BYOKError.invalidResponse }
            if choice.provider == .openai && type == "message" {
                for block in try objects(item["content"], maximum: 64) {
                    if block["type"] as? String == "output_text" { text += try string(block["text"], maximum: 180_000, allowEmpty: true) }
                    else if block["type"] as? String == "refusal" { text += try string(block["refusal"], maximum: 16_000, allowEmpty: true) }
                }
            } else if choice.provider == .anthropic && type == "text" { text += try string(item["text"], maximum: 180_000, allowEmpty: true) }
            else if type == (choice.provider == .openai ? "function_call" : "tool_use") {
                let args = choice.provider == .openai ? try string(item["arguments"], maximum: 65_536) : String(decoding: try JSONSerialization.data(withJSONObject: object(item["input"])), as: UTF8.self)
                _ = try parseObject(Data(args.utf8))
                calls.append(.init(id: try string(item[choice.provider == .openai ? "call_id" : "id"], maximum: 200), name: try string(item["name"], maximum: 64), argumentsJSON: args))
            }
        }
        let names = try Set(tools.map { try string(object($0["function"])["name"], maximum: 64) })
        guard calls.count <= 8, Set(calls.map(\.id)).count == calls.count, calls.allSatisfy({ names.contains($0.name) }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !calls.isEmpty else { throw BYOKError.invalidResponse }
        let saved = try JSONSerialization.data(withJSONObject: ["provider": choice.provider.rawValue, "model": choice.modelID, "items": items])
        guard saved.count <= 180_000 else { throw BYOKError.invalidResponse }
        return .init(assistantText: text, toolCalls: calls, continuationJSON: String(decoding: saved, as: UTF8.self))
    }
    static func failure(provider: BYOKProvider, status: Int, data: Data) -> BYOKError {
        var code: String
        switch status {
        case 401: code = "invalid_key"
        case 403: code = "provider_permission"
        case 402: code = "insufficient_credit"
        case 429: code = "provider_rate_limit"
        case 400, 404: code = "provider_rejected"
        default: code = "provider_unavailable"
        }
        if status == 400 || status == 429, data.count <= 16_384, let error = try? object(parseObject(data)["error"]) {
            if provider == .openai {
                let value = error["code"] as? String ?? ""
                if ["insufficient_quota", "credit_balance_exhausted"].contains(value) || error["type"] as? String == "insufficient_quota" { code = "insufficient_credit" }
                if ["organization_spend_limit_exceeded", "project_spend_limit_exceeded", "organization_usage_limit_exceeded"].contains(value) { code = "provider_spend_limit" }
            } else if let message = error["message"] as? String {
                if message.range(of: "credit balance.{0,40}(low|exhaust|insufficient)", options: [.regularExpression, .caseInsensitive]) != nil { code = "insufficient_credit" }
                else if message.range(of: "spend(ing)? limit", options: [.regularExpression, .caseInsensitive]) != nil { code = "provider_spend_limit" }
            }
        }
        return .providerCode(code)
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
    let agent: any AgentCompleting
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
