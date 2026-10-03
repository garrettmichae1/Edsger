import Foundation

/// Provider identity is distinct from a model ID. Add providers here and in the
/// native protocol adapter; settings, pickers and the local tool engine remain shared.
enum BYOKProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openai, anthropic
    var id: String { rawValue }
    var title: String { switch self { case .openai: "OpenAI"; case .anthropic: "Claude" } }
    var apiBaseURL: String { switch self { case .openai: "https://api.openai.com/v1"; case .anthropic: "https://api.anthropic.com/v1" } }
    var completionPath: String { switch self { case .openai: "/responses"; case .anthropic: "/messages" } }
}

struct BYOKModel: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct BYOKChoice: Identifiable, Codable, Equatable, Sendable {
    let provider: BYOKProvider
    let modelID: String
    var id: String { provider.rawValue + ":" + modelID }
}

struct BYOKConfiguration: Codable, Sendable {
    var models: [BYOKModel]
    var modelID: String
    var verifiedModelIDs: Set<String>
    var sharingConsent: Bool
    var verifiedAt: Date
}

enum BYOKError: LocalizedError, Equatable, TutorRequestFailure {
    case consentRequired, missingKey, busy, invalidKey, keychain, invalidResponse, providerUnavailable
    case providerCode(String)
    var errorDescription: String? {
        switch self {
        case .consentRequired: "Allow sharing with this provider in Settings → BYOK before using it."
        case .missingKey: "Add and test this provider’s API key in Settings → BYOK."
        case .busy: "Wait for the current response or connection test to finish."
        case .invalidKey: "Enter a valid API key without spaces or line breaks."
        case .keychain: "The API key could not be accessed securely. Unlock this device and try again."
        case .invalidResponse: "The provider returned an incomplete or invalid response. No new tool actions were executed."
        case .providerUnavailable: "Could not connect to your AI provider. Check your internet connection and the provider’s service status. Your selected model was kept."
        case .providerCode(let code):
            switch code {
            case "invalid_key": "This API key was rejected. Replace it in Settings → BYOK."
            case "provider_permission": "This key does not have permission for that model or API. Check its provider permissions."
            case "insufficient_credit": "This provider account needs API credit. Your Edsger allowance was not used."
            case "provider_spend_limit": "Your provider account reached a spend or usage limit. Check its API billing limits before trying again."
            case "provider_rate_limit": "The provider or connection is temporarily rate limited. Wait and try again."
            case "unsupported_model", "provider_rejected": "This model or request is unavailable for your API account. Choose another model in Settings → BYOK."
            case "tool_test_failed": "This model did not complete the agent tool test. Choose a different model."
            case "payload_too_large": "This request is too large for the secure AI connection. Use a smaller task or conversation."
            case "incomplete_response": "The model reached its response limit. Try a smaller task. No new tool actions were executed."
            default: "The provider request could not finish. Your selected provider was kept. Try again later."
            }
        }
    }
}

enum BYOKSecretValidation {
    static func clean(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...512).contains(key.utf8.count), key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw BYOKError.invalidKey }
        return key
    }
}

/// Old histories and interrupted batches may contain orphan results. Summarize
/// those as historical text; never send invalid tool roles or replay an operation.
enum AgentWireHistory {
    static func messages(_ source: [AgentChatMessage]) -> [[String: Any]] {
        var wire: [[String: Any]] = []
        var index = 0
        while index < source.count {
            let item = source[index]
            if item.role == .assistant, let calls = item.toolCalls, !calls.isEmpty {
                var results: [AgentChatMessage] = []
                var next = index + 1
                while next < source.count && source[next].role == .tool { results.append(source[next]); next += 1 }
                let ids = calls.map(\.id)
                let valid = Set(ids).count == calls.count && results.count == calls.count &&
                    Set(results.compactMap(\.toolCallID)) == Set(ids)
                if valid {
                    wire.append(assistant(text: item.text, calls: calls, continuation: historicalContinuation(item.continuationJSON)))
                    for result in results { wire.append(["role": "tool", "tool_call_id": result.toolCallID!, "content": result.text]) }
                } else {
                    let summary = ([item.text] + results.map { "Historical \($0.toolName ?? "tool") result: \($0.text)" }).filter { !$0.isEmpty }.joined(separator: "\n")
                    if !summary.isEmpty { wire.append(["role": "assistant", "content": summary]) }
                }
                index = next
                continue
            }
            switch item.role {
            case .user: wire.append(["role": "user", "content": item.text])
            case .assistant:
                if !item.text.isEmpty && !item.text.hasPrefix("I can read and edit your ") {
                    wire.append(assistant(text: item.text, calls: [], continuation: historicalContinuation(item.continuationJSON)))
                }
            case .tool: wire.append(["role": "assistant", "content": "Historical \(item.toolName ?? "tool") result: \(item.text)"])
            case .system: break
            }
            index += 1
        }
        return wire
    }

    static func assistant(text: String, calls: [AgentToolCall], continuation: String?) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !calls.isEmpty { message["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.argumentsJSON]] as [String: Any] } }
        if let continuation { message["edsger_continuation"] = continuation }
        return message
    }

    private static func historicalContinuation(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard var saved = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        guard saved["provider"] as? String == BYOKProvider.anthropic.rawValue else { return raw }
        // A new task refreshes the IDE system context and may trim old turns.
        // Claude thinking signatures are bound to the original exact prefix.
        // Strip ALL historical thinking; keep other native blocks/call pairs.
        // Within a live tool loop, assistant() preserves the full response.
        guard let items = saved["items"] as? [[String: Any]] else { return nil }
        saved["items"] = items.filter { !["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
        guard let data = try? JSONSerialization.data(withJSONObject: saved) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

enum AgentToolRegistry {
    static var specifications: [[String: Any]] {
        let path = ["path": stringProperty]
        return [
            function("read_runtime_guide", "Read Edsger’s active-language runtime guide only when uncertain about a runtime API, module or restriction. Fetch each needed topic once; do not routinely reread it.", ["topic": ["type": "string", "enum": AgentRuntimeDocumentation.topics.sorted()]], ["topic"]),
            function("list_files", "List source files in the project."),
            function("list_folders", "List project folders."),
            function("read_file", "Read a file.", path, ["path"]),
            function("write_file", "Create or overwrite a source file for the selected language, including tests.", ["path": stringProperty, "contents": stringProperty], ["path", "contents"]),
            function("replace_text", "Replace one exact, unique substring in an existing file. Read it first.", ["path": stringProperty, "old_text": stringProperty, "new_text": stringProperty], ["path", "old_text", "new_text"]),
            function("create_folder", "Create a project or nested folder.", path, ["path"]),
            function("select_file", "Select a file in the editor.", path, ["path"]),
            function("run_file", "Select a source file and run it with the active language runtime.", path, ["path"]),
            function("run_current", "Run the selected file."), function("stop_run", "Stop a running program."),
            function("read_output", "Read recent program output."),
            function("delete_file", "Delete a file. Blocked while safeguards are on.", path, ["path"]),
            function("delete_folder", "Delete a folder and its files. Blocked while safeguards are on.", path, ["path"]),
            function("calculate_math", "Perform one supported calculation on device with SymPy. Use explicit multiplication and radians. No Python programs or file access.", [
                "operation": ["type": "string", "enum": MathRequest.operations.sorted()],
                "expression": ["type": "string", "maxLength": 400],
                "variable": ["type": "string", "enum": ["x", "y", "z", "t", "a", "b", "c", "n"]],
                "lower": ["type": "string", "maxLength": 80], "upper": ["type": "string", "maxLength": 80]
            ], ["operation", "expression", "variable", "lower", "upper"])
        ]
    }

    static func validatedArguments(_ call: AgentToolCall) throws -> [String: Any] {
        guard call.argumentsJSON.utf8.count <= 65_536,
              let schema = specifications.compactMap({ $0["function"] as? [String: Any] }).first(where: { $0["name"] as? String == call.name }),
              let parameters = schema["parameters"] as? [String: Any], let properties = parameters["properties"] as? [String: Any],
              let args = try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any],
              Set(args.keys).isSubset(of: Set(properties.keys)),
              (parameters["required"] as? [String] ?? []).allSatisfy({ args[$0] is String }),
              args.values.allSatisfy({ $0 is String }) else { throw BYOKError.invalidResponse }
        if let path = args["path"] as? String {
            guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\0"), !path.contains("\\"), !path.hasPrefix("/"), !path.contains("..") else { throw BYOKError.invalidResponse }
        }
        if call.name == "read_runtime_guide" {
            guard let topic = args["topic"] as? String, AgentRuntimeDocumentation.topics.contains(topic) else { throw BYOKError.invalidResponse }
        }
        if call.name == "calculate_math" {
            let request = try JSONDecoder().decode(MathRequest.self, from: Data(call.argumentsJSON.utf8))
            guard request.isValid else { throw BYOKError.invalidResponse }
        }
        return args
    }

    private static var stringProperty: [String: Any] { ["type": "string"] }
    private static func function(_ name: String, _ description: String, _ properties: [String: Any] = [:], _ required: [String] = []) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description, "parameters": [
            "type": "object", "properties": properties, "required": required, "additionalProperties": false
        ]]]
    }
}
