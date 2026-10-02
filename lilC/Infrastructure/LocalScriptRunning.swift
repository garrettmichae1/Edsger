import Foundation

struct ScriptRunResult: Sendable { let output: String; let failed: Bool; let stopped: Bool }

protocol LocalScriptRunning: AnyObject, Sendable {
    func stop()
    func input(_ line: String)
    func eof()
    func run(path: URL, root: URL, onOutput: @escaping @Sendable (String) -> Void,
             onWaiting: @escaping @Sendable (Bool) -> Void) -> ScriptRunResult
}

/// Owns console state only; the engine and its values remain on the execution thread.
final class ScriptConsole: @unchecked Sendable {
    private let condition = NSCondition()
    private var stopped = false
    private var ended = false
    private var inputBuffer = ""
    private(set) var output = ""
    private var outputBytes = 0
    var onOutput: (@Sendable (String) -> Void)?
    var onWaiting: (@Sendable (Bool) -> Void)?
    var isStopped: Bool { condition.lock(); defer { condition.unlock() }; return stopped }
    func stop() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }
    func input(_ text: String) { condition.lock(); inputBuffer += text; condition.broadcast(); condition.unlock() }
    func eof() { condition.lock(); ended = true; condition.broadcast(); condition.unlock() }
    func write(_ text: String) throws {
        if isStopped { throw ScriptError.message("Stopped.") }
        guard outputBytes + text.utf8.count <= 1024 * 1024 else { throw ScriptError.message("Console output limit reached (1 MB).") }
        outputBytes += text.utf8.count
        output += text; onOutput?(text)
    }
    func readLine() -> String? {
        onWaiting?(true)
        condition.lock()
        while inputBuffer.isEmpty && !ended && !stopped { condition.wait() }
        var line: String?
        if !stopped, !inputBuffer.isEmpty {
            let end = inputBuffer.firstIndex(of: "\n").map { inputBuffer.index(after: $0) } ?? inputBuffer.endIndex
            line = String(inputBuffer[..<end]); inputBuffer.removeSubrange(..<end)
        }
        condition.unlock(); onWaiting?(false); return line
    }
}

enum ScriptError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func projectFile(_ path: String, root: URL) throws -> URL {
    guard !path.hasPrefix("/"), !path.contains("\0") else { throw ScriptError.message("Use a project-relative path.") }
    let target = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
    let base = root.standardizedFileURL.resolvingSymlinksInPath().path
    guard target.path.hasPrefix(base + "/") else { throw ScriptError.message("Files must stay inside this project.") }
    return target
}
