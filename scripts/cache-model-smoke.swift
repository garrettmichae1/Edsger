// Real production-client A/B test. Run baseline and cached modes sequentially.
import Foundation
import llama

private final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<String, Error>?
    func set(_ task: Task<String, Error>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task?.cancel() } }
    func clear() { lock.withLock { task = nil } }
}

private func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}

@main struct CacheModelSmoke {
    static func main() async throws {
        if let backendPath = ProcessInfo.processInfo.environment["LLAMA_BACKEND_DIR"] {
            ggml_backend_load_all_from_path(backendPath)
        }
        guard CommandLine.arguments.count >= 3 else {
            fatalError("Usage: cache-model-smoke MODEL baseline|cached [repetitions]")
        }
        let mode = CommandLine.arguments[2]
        precondition(["baseline", "cached"].contains(mode))
        let repetitions = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 5
        precondition((1...20).contains(repetitions))
        let client = LocalAgentClient(modelURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                                      cacheByteLimit: mode == "baseline" ? 0 : PromptReuseCache.defaultByteLimit)
        func record(_ name: String, _ output: String) async throws {
            let t = await client.lastTiming
            precondition(t.outcome == "success")
            precondition(t.promptTokens == t.cache.reusedTokens + t.cache.decodedTokens)
            precondition(t.cache.retainedBytes <= PromptReuseCache.defaultByteLimit)
            try emit(["mode": mode, "case": name, "output": output, "load_s": t.loadSeconds,
                      "prompt_s": t.promptSeconds, "generation_s": t.generationSeconds,
                      "total_s": t.totalSeconds, "first_token_s": t.firstTokenSeconds ?? -1,
                      "first_update_s": t.firstUpdateSeconds ?? -1, "input": t.promptTokens,
                      "output_tokens": t.generatedTokens, "cache": t.cache.outcome,
                      "reused": t.cache.reusedTokens, "decoded": t.cache.decodedTokens,
                      "cache_bytes": t.cache.retainedBytes, "capture_s": t.cache.captureSeconds,
                      "restore_s": t.cache.restoreSeconds, "tokenize_s": t.tokenizationSeconds])
        }
        func agent(_ name: String, _ wire: [[String: Any]]) async throws {
            let answer = try await client.complete(messagesJSON: JSONSerialization.data(withJSONObject: wire), toolsJSON: Data("[]".utf8))
            let calls = try answer.toolCalls.map { call in
                ["name": call.name, "arguments": try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))] as [String: Any]
            }
            let canonical = try JSONSerialization.data(withJSONObject: ["message": answer.assistantText, "tool_calls": calls], options: [.sortedKeys])
            try await record(name, String(decoding: canonical, as: UTF8.self))
        }
        var wire: [[String: Any]] = [
            ["role": "system", "content": "Current project: demo. Language: C using PicoC. Current file: hello.c. Files: hello.c. Paths relative to demo. Deleting: OFF. Use no external libraries or function pointers."],
            ["role": "user", "content": "Create math.h with a complete function int square(int n) that returns n*n. Do not run it."]
        ]
        try await agent("agent-first", wire)
        let code = "#ifndef MATH_H\n#define MATH_H\n\nint square(int n);\n\n#endif"
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["path": "math.h", "contents": code]), as: UTF8.self)
        wire += [["role": "assistant", "content": "Creating math.h with the square function", "tool_calls": [["function": ["name": "write_file", "arguments": args]]]],
                 ["role": "tool", "content": "Created or updated math.h."], ["role": "user", "content": AgentCompletionReview.prompt]]
        try await agent("agent-review", wire)
        wire += [["role": "assistant", "content": "Verifying math.h implementation", "tool_calls": [["function": ["name": "read_file", "arguments": "{\"path\":\"math.h\"}"]]]],
                 ["role": "tool", "content": code]]
        try await agent("agent-repair", wire)
        wire[0]["content"] = "Current project: other. Language: C using PicoC. Files: main.c. Do not delete files."
        try await agent("agent-project-switch", wire)
        if mode == "cached" {
            let switched = await client.lastTiming
            precondition(switched.cache.reusedTokens == 0)
        }

        let first = TutorMessage(role: .user, text: "Write only a complete C function int square(int n) that returns n*n. No explanation.")
        let firstAnswer = try await client.reply(messages: [first], onUpdate: { _ in })
        try await record("chat-first", firstAnswer)
        let chat = [first, TutorMessage(role: .assistant, text: "```c\nint square(int n) {\n    return n * n;\n}\n```"),
                    TutorMessage(role: .user, text: "Now explain what return does in one sentence.")]
        for index in 0..<repetitions {
            let answer = try await client.reply(messages: chat, onUpdate: { _ in })
            try await record("chat-followup-\(index)", answer)
        }
        let unicode = [TutorMessage(role: .user, text: "Translate café into English. Answer in one short sentence.")]
        try await record("chat-unicode", client.reply(messages: unicode, onUpdate: { _ in }))
        // The obsolete long turn must be dropped as a complete turn by the client.
        let truncated = [TutorMessage(role: .user, text: String(repeating: "old context ", count: 4000)),
                         TutorMessage(role: .assistant, text: "Old answer.")] + unicode
        try await record("chat-truncated", client.reply(messages: truncated, onUpdate: { _ in }))
        for (name, text) in [("math-first", "Integrate x squared from 0 to 1"), ("math-next", "Find RREF of [[1,1,2],[2,3,5]]")] {
            let answer = try await client.mathPlan(messages: [.init(role: .user, text: text)])
            try await record(name, String(describing: answer))
        }
        try await record("chat-after-math", client.reply(messages: chat, onUpdate: { _ in }))

        if mode == "cached" {
            let handle = CancellationHandle()
            let task = Task { try await client.reply(messages: chat) { _ in handle.cancel() } }
            handle.set(task)
            do { _ = try await task.value; preconditionFailure("Streaming cancellation must propagate") }
            catch is CancellationError {}
            handle.clear()
            let cancelled = await client.lastTiming
            precondition(cancelled.outcome == "cancelled" && cancelled.cache.retainedBytes == 0)
            let recovered = try await client.reply(messages: chat, onUpdate: { _ in })
            let recoveredTiming = await client.lastTiming
            precondition(recoveredTiming.cache.reusedTokens == 0)
            try await record("recovered-after-cancellation", recovered)
            client.handleMemoryPressure()
            let pressureAnswer = try await client.reply(messages: chat, onUpdate: { _ in })
            let pressureTiming = await client.lastTiming
            precondition(pressureTiming.cache.reusedTokens == 0 && pressureTiming.cache.retainedBytes == 0)
            precondition(pressureTiming.cache.outcome == "memoryPressure")
            try await record("memory-pressure-fallback", pressureAnswer)
        }
    }
}
