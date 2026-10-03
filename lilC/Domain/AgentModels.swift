import Foundation

struct AgentCompletion: Sendable {
    var assistantText: String
    var toolCalls: [AgentToolCall]
    var continuationJSON: String? = nil
}

protocol AgentCompleting: Sendable {
    func complete(messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion
    func complete(messagesJSON: Data, toolsJSON: Data,
                  onStatus: @escaping GenerationStatusHandler) async throws -> AgentCompletion
}

extension AgentCompleting {
    func complete(messagesJSON: Data, toolsJSON: Data,
                  onStatus: @escaping GenerationStatusHandler) async throws -> AgentCompletion {
        onStatus(.generatingResponse)
        return try await complete(messagesJSON: messagesJSON, toolsJSON: toolsJSON)
    }
}

enum AgentTransportError: LocalizedError, Equatable {
    case notConfigured
    case invalidEndpoint
    case missingAPIKey
    case httpStatus(Int, String)
    case decoding
    case cancelled
    case safeguards

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Edsger is not connected to the worker yet."
        case .invalidEndpoint:
            "The agent only talks to the app’s HTTPS hosts."
        case .missingAPIKey:
            "Could not reach the agent. Turn on Share with AI and try again."
        case .httpStatus(let code, let detail):
            if code == 429 {
                detail.isEmpty ? "Free agent allowance used for this 12-hour window. Try later, or connect GitHub you already have." : detail
            } else {
                "Agent request failed (\(code))."
            }
        case .decoding:
            "The agent response could not be read."
        case .cancelled:
            "Stopped."
        case .safeguards:
            "Safeguards are on. Turn them off in Settings to let the agent delete."
        }
    }
}

enum AgentEndpointPolicy {
    static func validatedGateway(_ raw: String, allowedHosts: [String]) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            throw AgentTransportError.invalidEndpoint
        }
        let scheme = url.scheme?.lowercased() ?? ""
        #if DEBUG
        if (host == "localhost" || host == "127.0.0.1"), scheme == "http" || scheme == "https" {
            return url
        }
        #endif
        guard scheme == "https" else { throw AgentTransportError.invalidEndpoint }
        let blocked = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]
        if blocked.contains(host.lowercased()) { throw AgentTransportError.invalidEndpoint }
        if hostAllowed(host, allowedHosts: allowedHosts) {
            return url
        }
        throw AgentTransportError.invalidEndpoint
    }

    private static func hostAllowed(_ host: String, allowedHosts: [String]) -> Bool {
        let value = host.lowercased()
        if allowedHosts.contains(where: { $0.lowercased() == value }) { return true }
        if value.hasSuffix(".workers.dev") { return true }
        return false
    }
}

struct AgentChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
        case tool
    }

    let id: UUID
    var role: Role
    var text: String
    var toolName: String?
    var createdAt: Date
    var toolCalls: [AgentToolCall]?
    var toolCallID: String?
    var continuationJSON: String?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        toolName: String? = nil,
        createdAt: Date = Date(),
        toolCalls: [AgentToolCall]? = nil,
        toolCallID: String? = nil,
        continuationJSON: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolName = toolName
        self.createdAt = createdAt
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.continuationJSON = continuationJSON
    }
}

/// Presentation only: saved messages and the model's tool transcript stay intact.
enum AgentTranscriptPresentation {
    static func visibleMessages(_ messages: [AgentChatMessage]) -> [AgentChatMessage] {
        let firstRequest = messages.firstIndex { $0.role == .user } ?? messages.endIndex
        return messages.enumerated().compactMap { index, message in
            guard message.role != .system else { return nil }
            if message.role == .assistant && message.text.isEmpty { return nil }
            if index < firstRequest, message.role == .assistant,
               message.text.hasPrefix("I can read and edit your ") { return nil }
            return message
        }
    }

    static func status(_ raw: String) -> String {
        switch raw {
        case GenerationStatus.waiting.label: return "Waiting for the model…"
        case GenerationStatus.loadingModel.label: return "Loading the model…"
        case GenerationStatus.preparingPrompt.label: return "Reading your request…"
        case GenerationStatus.generatingResponse.label: return "Writing a response…"
        default:
            guard raw.hasPrefix("Working: ") else { return raw }
            switch String(raw.dropFirst("Working: ".count)) {
            case "read file": return "Reading code…"
            case "write file", "replace text": return "Updating code…"
            case "run file", "run current": return "Running code…"
            case "read output": return "Checking output…"
            case "list files", "list folders": return "Looking through the project…"
            case "create folder": return "Creating a folder…"
            case "select file": return "Opening a file…"
            case "delete file", "delete folder": return "Removing an item…"
            case "stop run": return "Stopping the program…"
            case "calculate math": return "Calculating on device…"
            default: return "Working…"
            }
        }
    }
}

struct AgentToolActivity {
    let title: String
    let symbol: String
    let showsDetailsInitially: Bool

    init(message: AgentChatMessage) {
        let firstLine = message.text.components(separatedBy: .newlines).first ?? ""
        let blocked = ["Change not applied.", "File not found.", "Folder not found.", "Missing ", "The old_text must", "Blocked", "Unknown tool", "Could not", "Cannot ", "Invalid ", "Rejected ", "Safeguards are on.", "Select a file "]
            .contains { message.text.hasPrefix($0) }
        showsDetailsInitially = blocked
        if blocked {
            title = Self.shortLine(firstLine.isEmpty ? "Action needs attention" : firstLine)
            symbol = "exclamationmark.circle"
            return
        }
        switch message.toolName {
        case "write_file", "replace_text", "delete_file", "delete_folder", "create_folder":
            // Only use success wording that the actual workspace returned.
            if ["Created ", "Updated ", "Deleted "].contains(where: message.text.hasPrefix) {
                title = Self.shortLine(firstLine)
            } else { title = "Change result" }
            symbol = "doc.text"
        case "run_file", "run_current":
            title = message.text.hasPrefix("Program is still running") ? "Program still running" : "Run output"
            symbol = "play.circle"
        case "read_file": title = "File contents"; symbol = "doc.text.magnifyingglass"
        case "read_output": title = "Console output"; symbol = "terminal"
        case "list_files": title = "Project files"; symbol = "doc.on.doc"
        case "list_folders": title = "Project folders"; symbol = "folder"
        case "select_file": title = "File selection"; symbol = "doc"
        case "stop_run": title = "Program stop result"; symbol = "stop.circle"
        case "calculate_math": title = "On-device math result"; symbol = "function"
        default: title = "Activity details"; symbol = "ellipsis.circle"
        }
    }

    private static func shortLine(_ text: String) -> String {
        text.count > 140 ? String(text.prefix(140)) + "…" : text
    }
}

struct AgentToolCall: Equatable, Codable, Sendable {
    var id: String
    var name: String
    var argumentsJSON: String
}

/// Build-time agent routing. Provider keys never belong in source, Info.plist, or UserDefaults.
enum AgentRuntimeConfig {
    /// Flip to true in a later release to show Agent tab, Settings, and IAP again. Architecture stays in the tree.
    static let surfacesVisibleInThisRelease = true

    static let model = "gpt-4o-mini"
    #if DEBUG
    static let gatewayURL = "http://127.0.0.1:8787/v1"
    #else
    static let gatewayURL = "https://api.lilc.app/v1"
    #endif
    static let allowedHosts = ["api.lilc.app"]
}

/// One bounded completion review after mutations, before claiming the task is done.
enum AgentCompletionReview {
    /// App-inserted review continues the active task; it must never allow budgeting
    /// to discard that task's request, snapshot, or earlier tool results.
    static func userTurnIndices(in messages: [[String: Any]]) -> [Int] {
        messages.indices.filter {
            messages[$0]["role"] as? String == "user" && messages[$0]["content"] as? String != prompt
        }
    }

    static let prompt = """
    Before finishing, verify the original request against the file changes you actually made. Does the code implement the requested behavior, including function bodies rather than only declarations? If something is missing, read the file and fix it with tools now. Otherwise give a brief accurate final answer. Do not repeat successful changes.
    """
}
