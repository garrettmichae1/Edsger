// Real model test: exact production prompts, sampler, grammar, cache, and actor lifecycle.
import Foundation
import llama

private enum SmokeFailure: Error { case failed(String) }
private func require(_ value: Bool, _ description: String) throws {
    if !value { throw SmokeFailure.failed(description) }
}

@main struct MiniModelSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else {
            throw SmokeFailure.failed("Pass the Mini GGUF and Standard GGUF paths")
        }
        #if os(Linux)
        if let backends = ProcessInfo.processInfo.environment["LLAMA_BACKEND_PATH"] {
            ggml_backend_load_all_from_path(backends)
        }
        #endif
        let engine = LocalAgentClient(modelURL: URL(fileURLWithPath: CommandLine.arguments[2]),
                                      miniModelURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let mini = ModelBoundChatClient(model: .mini, engine: engine)
        let questions = [
            "In one short sentence, state Newton's second law and explain its variables.",
            "Show a 2 by 2 identity matrix using LaTeX bmatrix in a display equation. One brief sentence after it."
        ]
        for question in questions {
            let text = try await mini.reply(messages: [.init(role: .user, text: question)], onUpdate: { _ in })
            try require(!text.isEmpty && !text.contains("<think>") && !text.contains("tool_calls"), "Visible answer without control tokens")
            let timing = await engine.lastTiming
            try require(timing.modelName == "mini", "Mini actually generated the answer")
            if question.contains("Newton") {
                try require(text.lowercased().contains("mass") && text.lowercased().contains("acceleration"), "Physics smoke answer")
            } else {
                try require(MathMessage.parse(text).contains { if case .equation = $0 { return true }; return false }, "Complete display math parses")
            }
            print("CHAT: \(text)\nTIMING: model=\(timing.modelName) firstToken=\(timing.firstTokenSeconds ?? -1) total=\(timing.totalSeconds)")
        }
        let cases: [(String, MathRequest?)] = [
            ("What is 15% of 80?", .init(operation: "evaluate", expression: "15/100*80")),
            ("Integrate x squared from 0 to 1", .init(operation: "integrate", expression: "x^2", lower: "0", upper: "1")),
            ("Find RREF of [[1,1,2],[2,3,5]]", .init(operation: "rref", expression: "[[1,1,2],[2,3,5]]")),
            ("Find the variance of 1,2,3", nil),
            ("Calculate the limit of sin(x)/x as x approaches 0", nil)
        ]
        for (question, expected) in cases {
            let plan = try await mini.mathPlan(messages: [.init(role: .user, text: question)])
            let loaded = await engine.loadedChoice
            try require(loaded == .standard, "Mini chat uses the existing Standard math planner")
            if let expected {
                guard case .calculate(let request) = plan else { throw SmokeFailure.failed(question) }
                try require(request == expected, "Exact interpretation: \(question) => \(request)")
            } else {
                switch plan {
                case .clarify, .unsupported: break
                default: throw SmokeFailure.failed("Must clarify/reject: \(question)")
                }
            }
            print("PLAN: \(question) => \(plan)")
        }
        let followup: [TutorMessage] = [.init(role: .user, text: "Find variance of [1,2,3]"),
            .init(role: .assistant, text: "Sample or population?"), .init(role: .user, text: "Population")]
        guard case .calculate(let request) = try await mini.mathPlan(messages: followup), request.operation == "variance" else {
            throw SmokeFailure.failed("Math follow-up")
        }
        _ = try await mini.reply(messages: [.init(role: .user, text: "Say hello in one sentence.")], onUpdate: { _ in })
        try require(await engine.loadedChoice == .mini, "Return to Mini after math")
        await engine.unloadMiniModel()
        try require(await engine.loadedChoice == nil, "Unloading releases the model and context")
        do {
            _ = try await mini.reply(messages: [.init(role: .user, text: "Write a detailed story about a voyage to Mars.")], onUpdate: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
            throw SmokeFailure.failed("Streaming cancellation")
        } catch is CancellationError {}
        await engine.unloadMiniModel()
        try require(await engine.loadedChoice == nil, "Stopped Mini can be released")
        print("PASS: live Mini chat/formatting, Standard math planning, model transitions, and release")
    }
}
