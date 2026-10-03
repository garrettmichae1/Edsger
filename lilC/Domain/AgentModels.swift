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

/// App-authored reference. Available through the shared tool engine to every
/// provider; never downloaded, model-authored, or interpreted as executable code.
enum AgentRuntimeDocumentation {
    static let version = "1"
    static let topics: Set<String> = ["overview", "files", "modules", "limits"]
    static func read(language: String, topic: String) -> String? {
        guard topics.contains(topic), let text = guides[language]?[topic] else { return nil }
        return "Edsger runtime guide v\(version) · \(language) · \(topic)\n" + text
    }
    private static let guides: [String: [String: String]] = [
        "c": [
            "overview": """
            C runs in the bundled PicoC interpreter, not GCC/Clang and not a POSIX shell. Use .c and .h source files, simple complete functions, loops, arrays and structs. One main() is the entry point. Include the required headers and provide function bodies. Avoid function pointers and qsort; they are unsupported by this app. Prefer small explicit algorithms. Validate behavior with run_file/run_current and inspect actual output rather than assuming desktop C behavior.
            Example: #include <stdio.h> followed by int main(void) { printf("Hello\\n"); return 0; }.
            """,
            "files": """
            Tool paths are relative to the active project. The editor accepts .c/.h files. Read existing files before edits; replace_text requires one unique exact match. stdio file access uses project-relative paths. Do not use absolute paths or parent traversal. Deletion tools are blocked when Protect files from deletion is enabled; edits are still allowed. Generated programs can change project data, so review writes and keep restore points. Code execution starts at the selected .c file and uses the active project as its include/file root.
            """,
            "modules": """
            There is no package manager, linker, external native library loading or desktop build command. Use project-local headers and the bundled PicoC adapters: stdio.h, stdlib.h, string.h, math.h, ctype.h, errno.h, stdbool.h and time.h. These are limited adapters, not a complete libc. Put simple static helper definitions in headers when needed. Do not assume POSIX headers, sockets, pthreads, fork/exec, system(), qsort or arbitrary third-party APIs exist. Run one main() per project.
            """,
            "limits": """
            PicoC is an educational interpreter with C feature limits and cooperative Stop. system() is disabled. Unsupported library calls can fail even if similar code compiles on a desktop. Native operations may need to return before cancellation is observed. Check runtime diagnostics, then simplify the source; do not invent successful test results or suggest bypassing the interpreter restrictions. Use calculate_math for supported symbolic math rather than unavailable libraries.
            """
        ],
        "python": [
            "overview": """
            Python runs in bundled CPython 3.14.7 on iPhone. Execute the selected .py script, using print(), input(), four-space indentation, functions, classes and local imports. Each IDE run uses a fresh interpreter; files persist, Python globals do not. Console input may wait for the user; EOF must be handled. There is no pip, desktop shell, GUI, background thread, subprocess or network access.
            Example: def square(x): return x * x followed by print(square(3)).
            """,
            "files": """
            Use project-relative paths with normal open() or pathlib. Project files can be read/written; bundled Python resources are read-only. Native audit policy resolves paths and symlinks and rejects outside-project writes, parent traversal, raw file descriptors and directory-fd tricks. Do not modify Python bootstrap globals or use ctypes to bypass rules. Programs may modify project data; the agent deletion-tool safeguard is not a blanket ban on program writes. Existing checkpoints support recovery. Read the current source before editing it.
            """,
            "modules": """
            Use local .py modules and the bundled standard library, such as math, json, collections and pathlib. Project-local imports start at the active project. Do not assume packages are installed or run pip. SymPy is bundled for Edsger's dedicated calculate_math tool, not promised as an import in ordinary IDE scripts. ctypes/_ctypes, subprocess, multiprocessing, threading, socket, signal, resource and unsafe native facilities are restricted. Prefer calculate_math for supported symbolic operations and respect its expression/operation limits.
            """,
            "limits": """
            The host installs native file/import/network/process restrictions before CPython initialization and enforces them during script execution and cleanup. Python callbacks cannot turn them off. Do not access app credentials, environment/process controls, other projects or arbitrary native modules. Stop is cooperative and native work can delay cancellation; console output is capped at 1 MB. Avoid unbounded loops, huge allocations and output floods. A fresh interpreter is not a separate OS process or proof against every hostile-runtime exploit; generate small reviewed programs.
            """
        ],
        "javascript": [
            "overview": """
            JavaScript runs in Apple's JavaScriptCore console, not Node.js or a browser. Use .js, console.log(), input(prompt), and ordinary functions/arrays/objects. input returns null at EOF. Source is parsed as an ECMAScript 2025 script and instrumented for cooperative Stop. Use synchronous console programs. There is no DOM, document/window, fetch, npm, timers or Node process/Buffer APIs.
            Example: const value = input('Number:'); if (value !== null) console.log(Number(value) * 2);
            """,
            "files": """
            Use readFile(path) and writeFile(path, text) for project text files, with project-relative paths. IDE tool writes accept .js source. Read existing files before edits. All file operations stay within the active project. Do not use Node fs/path packages, absolute paths or parent traversal to access other projects. Generated programs can change project data; review writes and use restore points. Runtime errors refer to source locations before Stop instrumentation when available.
            """,
            "modules": """
            Local CommonJS-style modules are supported: require('./helper') or require('./helper.js') and module.exports. Resolution is relative to the importing file and constrained to the project. No npm registry or Node built-in modules are supplied. ES import/export declarations are unsupported because files run as scripts. Use module.exports = { name } and const { name } = require('./helper') instead. Keep dependencies as local .js files.
            """,
            "limits": """
            eval and Function constructors, including constructor-based variants, are disabled to prevent bypassing Stop instrumentation. Loops and function entries have cancellation checkpoints; long native operations can delay Stop. Do not attempt dynamic-code workarounds, network calls, GUI APIs or unsupported async timers. Use calculate_math for supported symbolic calculations and read_output to inspect actual results.
            """
        ],
        "lua": [
            "overview": """
            Lua runs in the bundled Lua 5.5.1 interpreter, offline. Use .lua, print(), io.read(), io.write(), tables, functions and coroutines. Run the selected script. Handle nil at EOF. This is the app console, not a desktop shell. Process commands, LuaRocks, native modules and the debug library are unavailable.
            Example: local text = io.read(); if text then print(string.upper(text)) end.
            """,
            "files": """
            io.open(name, mode), io.lines(name), loadfile(name) and dofile(name) resolve within the active project. Use project-relative paths. IDE edits accept .lua source; read it before changing it. File writes can change project data, so review them and preserve restore points. io.popen, io.tmpfile, io.input and io.output are unavailable. Do not attempt absolute/parent paths to other projects or the app's private files.
            """,
            "modules": """
            require('helper') loads helper.lua or helper/init.lua from the project. Dotted names resolve to local subfolders. Return a table from the module. Built-in os, io, math, string, table, utf8 and coroutine are provided with the app's restrictions. No C/native-module loading or LuaRocks installation is supported. Circular local imports fail. Text chunks may use load, but bytecode loading is disabled.
            """,
            "limits": """
            os.execute, os.exit, os.getenv, os.setlocale, os.remove, os.rename and os.tmpname are removed. io.popen is removed; the debug library is unavailable. File paths remain project-scoped. Use small bounded loops, handle EOF, inspect real console output, and use Stop when needed. calculate_math supplies supported symbolic operations independently of Lua packages. Do not suggest bypassing the host restrictions.
            """
        ]
    ]
}
