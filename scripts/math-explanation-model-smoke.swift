// Host smoke with production planner, reply routing, prompts, models and Python calculator.
// Representative reasoning is inspected by a human; these assertions aren't proof verification.
import Foundation
#if os(Linux)
import llama
#endif

private enum SmokeFailure: Error { case failed(String) }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SmokeFailure.failed(message) }
}

private struct HostMathCalculator: MathCalculating {
    let python: URL
    let bootstrap: URL
    func calculate(_ request: MathRequest) async throws -> MathCalculation {
        let process = Process(), output = Pipe()
        process.executableURL = python
        process.arguments = ["-c", """
        import runpy, sys
        engine = runpy.run_path(sys.argv[1], init_globals={'_math_packages': ''})
        print(engine['_calculate_json'](sys.argv[2]))
        """, bootstrap.path, String(decoding: try JSONEncoder().encode(request), as: UTF8.self)]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "Host Python calculator failed")
        return try JSONDecoder().decode(MathCalculation.self, from: data)
    }
}

private actor CountingTutor: MathExplanationCompleting {
    let base: ModelBoundChatClient
    private(set) var calls = 0
    init(base: ModelBoundChatClient) { self.base = base }
    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try await reply(messages: messages, onStatus: { _ in }, onUpdate: onUpdate)
    }
    func reply(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
               onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        calls += 1
        return try await base.reply(messages: messages, onStatus: onStatus, onUpdate: onUpdate)
    }
    func explainCalculation(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
                            onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        calls += 1
        return try await base.explainCalculation(messages: messages, onStatus: onStatus, onUpdate: onUpdate)
    }
}

@main struct MathExplanationModelSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 5 else {
            throw SmokeFailure.failed("Pass Mini GGUF, Standard GGUF, host Python with SymPy, and math bootstrap paths")
        }
        #if os(Linux)
        if let path = ProcessInfo.processInfo.environment["LLAMA_BACKEND_PATH"] { ggml_backend_load_all_from_path(path) }
        #endif
        let engine = LocalAgentClient(modelURL: URL(fileURLWithPath: CommandLine.arguments[2]),
            miniModelURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let calculator = HostMathCalculator(python: URL(fileURLWithPath: CommandLine.arguments[3]),
            bootstrap: URL(fileURLWithPath: CommandLine.arguments[4]))
        let baseQuestion = "Integrate x^2 * ln(1+x) with respect to x from 0 to 1."
        for model in [ChatModel.mini, .standard] {
            let bound = ModelBoundChatClient(model: model, engine: engine)
            let tutor = CountingTutor(base: bound)
            let client = CalculatingTutorClient(tutor: tutor, planner: bound, calculator: calculator)
            for suffix in ["", " Explain briefly.", " Show integration by parts in at most six compact steps."] {
                let before = await tutor.calls
                let start = ContinuousClock().now
                let reply = try await client.reply(messages: [.init(role: .user, text: baseQuestion + suffix)], onUpdate: { _ in })
                try require(reply.contains("Calculated on device") && reply.contains(#"\log"#) && reply.contains(#"\frac{5}{18}"#), "Correct calculator result: \(reply)")
                let calls = await tutor.calls - before
                if suffix.isEmpty {
                    try require(calls == 0 && !reply.contains("AI-generated"), "Default request started an explanation")
                    try require(await engine.loadedChoice == .standard, "Default result switched to another model")
                    print("PASS \(model.rawValue) answer-only: zero explanatory calls, total=\(start.duration(to: .now))")
                } else {
                    try require(calls == 1 && reply.contains("**Explanation** · AI-generated"), "Requested explanation routing")
                    try require(await engine.loadedChoice == .standard, "Requested math explanation must reuse Standard")
                    let explanation = reply.components(separatedBy: "**Explanation** · AI-generated\n\n").last ?? ""
                    let wordCount = explanation.split(whereSeparator: \.isWhitespace).count
                    print("EXPLANATION \(model.rawValue)\(suffix): words=\(wordCount)\n\(explanation)\nEND EXPLANATION")
                    try require(wordCount <= (suffix.contains("briefly") ? 160 : 260), "Explanation exceeded smoke length tolerance: \(wordCount)")
                    try require(!explanation.contains("37/180") && !explanation.contains(#"\frac{37}{180}"#), "Known conflicting approximation")
                    if suffix.contains("parts") {
                        let compact = explanation.filter { !$0.isWhitespace }
                        try require(compact.contains(#"\frac{x^3}{3}"#) || compact.contains(#"\frac{x^{3}}{3}"#) || compact.contains("x^3/3"), "Example antiderivative in the requested derivation")
                        try require(!explanation.lowercased().contains("taylor"), "Exact derivation switched to a series")
                    }
                    print("PASS \(model.rawValue)\(suffix): words=\(wordCount), total=\(start.duration(to: .now))")
                }
            }
        }
        print("PASS both chat choices: default result only; requested explanations reuse Standard")
    }
}
