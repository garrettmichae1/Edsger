import Foundation

struct MathRequest: Codable, Equatable, Sendable {
    let operation: String
    let expression: String
    var variable = "x"
    var lower = ""
    var upper = ""

    static let operations: Set<String> = [
        "evaluate", "simplify", "expand", "factor", "differentiate", "integrate", "solve",
        "determinant", "inverse", "rref", "rank", "mean", "median", "variance",
        "sample_variance", "stddev", "sample_stddev"
    ]
    var isValid: Bool {
        Self.operations.contains(operation) && !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        expression.utf8.count <= 400 && ["x", "y", "z", "t", "a", "b", "c", "n"].contains(variable) &&
        lower.utf8.count <= 80 && upper.utf8.count <= 80 &&
        (operation == "integrate" ? lower.isEmpty == upper.isEmpty : lower.isEmpty && upper.isEmpty)
    }
    var label: String {
        switch operation {
        case "differentiate": "Derivative with respect to \(variable)"
        case "integrate": "Integral with respect to \(variable)"
        case "variance": "Population variance"
        case "sample_variance": "Sample variance"
        case "stddev": "Population standard deviation"
        case "sample_stddev": "Sample standard deviation"
        case "rref": "Reduced row echelon form"
        default: operation.capitalized
        }
    }
}

struct MathCalculation: Codable, Sendable {
    let ok: Bool
    var input: String?
    var latex: String?
    var exact: String?
    var note: String?
    var error: String?
    var steps: [MathWorkStep]?

    static func unavailable(_ reason: String) -> Self { .init(ok: false, error: reason) }
    func answer(for request: MathRequest) -> String? {
        guard ok, let input, !input.isEmpty, let latex, !latex.isEmpty, let exact, !exact.isEmpty else { return nil }
        return "**\(request.label)** · Calculated on device\n\nInterpreted input:\n\\[\(input)\\]\n\nResult:\n\\[\(latex)\\]\n\n\(note ?? "")"
    }

    // Recognize the app's successful result format, never use its text as calculator input.
    static func isAnswer(_ text: String) -> Bool {
        text.range(of: #"^\*\*[^*\n]+\*\* · Calculated on device\n\nInterpreted input:\n\\\["#,
                   options: .regularExpression) != nil && text.contains("\n\nResult:\n\\[")
    }
}

/// Equations and captions supplied only by the bounded on-device calculator.
struct MathWorkStep: Codable, Equatable, Sendable {
    let title: String
    let latex: String

    static func render(_ steps: [Self]?) -> String? {
        guard let steps, (1...6).contains(steps.count),
              steps.allSatisfy({ !$0.title.isEmpty && $0.title.utf8.count <= 100 &&
                  !$0.latex.isEmpty && $0.latex.utf8.count <= 1400 }),
              steps.reduce(0, { $0 + $1.title.utf8.count + $1.latex.utf8.count }) <= 5000 else { return nil }
        return steps.enumerated().map { index, step in
            "**\(index + 1). \(step.title)**\n\n\\[\(step.latex)\\]"
        }.joined(separator: "\n\n")
    }
}

protocol MathCalculating: Sendable {
    func calculate(_ request: MathRequest) async throws -> MathCalculation
}

/// Optional work capability leaves existing calculator clients and planner schemas unchanged.
protocol IntegralWorkCalculating: MathCalculating {
    func calculateIntegralWork(_ request: MathRequest) async throws -> MathCalculation
}

/// Optional capability for a focused explanation prompt; existing tutor clients remain compatible.
protocol MathExplanationCompleting: TutorCompleting {
    func explainCalculation(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
                            onUpdate: @escaping @Sendable (String) -> Void) async throws -> String
}

/// Presentation preference for the latest request only; never changes calculator input.
enum MathExplanationStyle: Equatable {
    case answerOnly, brief, steps

    static func requested(in text: String) -> Self {
        let text = text.replacingOccurrences(of: "’", with: "'")
        func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        // Explicit answer-only instructions take priority over incidental explanation words.
        if matches(#"\b(answer|result)\s+only\b|\bjust\s+(give\s+)?(me\s+)?(the\s+)?(answer|result)\b|\b(no|without|skip|omit)\s+((an?|any|the|extra)\s+)*(explanations?|steps?|derivations?|reasoning|working|work)\b|\b(don't|do\s+not|no\s+need\s+to)\s+(explain|derive|show\s+((the|your)\s+)?(steps|work|working)|(include|give|provide)\s+((an?|any|the)\s+)?(explanation|steps|reasoning|work))\b"#) {
            return .answerOnly
        }
        if matches(#"\bstep[\s-]+by[\s-]+step\b|\b(show|give|include|with)\s+(me\s+)?((the|your|all|full)\s+)*(steps|work|working|derivation)\b|\bshow\s+(me\s+)?how\b|\b(derive|derivation|prove|proof)\b|\b(walk|talk)\s+me\s+through\b|\bbreak\s+it\s+down\b|\bintegration\s+by\s+parts\b"#) {
            return .steps
        }
        if matches(#"\b(explain|explanation|why|justify|reasoning)\b|\bhow\s+(did|do|does|can|to|is|was|were|would|should|you)\b"#) {
            return .brief
        }
        return .answerOnly
    }

    var instructions: String {
        switch self {
        case .answerOnly: "Return only the calculator result."
        case .brief: "Describe the method in two to four short sentences of prose, normally under 100 words. Do not write or evaluate intermediate equations, give numerical approximations, or repeat the supplied result. Leave worked calculations for an explicit request for steps."
        case .steps: "Give one focused derivation, normally three to six compact steps and under 180 words. Expand only if the user explicitly requests more detail. Honor a requested method when you can explain it reliably."
        }
    }
}

/// Calculator results are published before explanation; the model never supplies the result card.
struct CalculatingTutorClient: TutorCompleting {
    let tutor: any TutorCompleting
    let planner: any MathPlanning
    let calculator: any MathCalculating

    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try await reply(messages: messages, onStatus: { _ in }, onUpdate: onUpdate)
    }

    func reply(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
               onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        guard let question = messages.last(where: { $0.role == .user }) else {
            return try await tutor.reply(messages: messages, onStatus: onStatus, onUpdate: onUpdate)
        }
        let followsCalculation = messages.last?.role == .user && MathIntent.isExplanationFollowup(question.text) &&
            messages.dropLast().last.map { $0.role == .assistant && MathCalculation.isAnswer($0.text) } == true
        let calculationMessages: [TutorMessage]
        if followsCalculation {
            guard let recovered = MathIntent.priorCalculationMessages(messages) else {
                return publish("Which calculation would you like explained? Please send its expression and operation again.", onUpdate)
            }
            calculationMessages = recovered
        } else {
            guard MathIntent.isCandidate(messages) else {
                return try await tutor.reply(messages: messages, onStatus: onStatus, onUpdate: onUpdate)
            }
            calculationMessages = messages
        }
        let calculationQuestion = calculationMessages.last(where: { $0.role == .user }) ?? question
        let explanationStyle = MathExplanationStyle.requested(in: question.text)
        let plan: MathPlan
        do {
            if let request = MathIntent.directArithmetic(calculationQuestion.text) { plan = .calculate(request) }
            else { plan = try await planner.mathPlan(messages: calculationMessages, onStatus: onStatus) }
        } catch {
            try propagateCancellation(error)
            return publish("I couldn't interpret that calculation reliably. Please try one calculation at a time, with its expression or equation and the operation you want.", onUpdate)
        }
        try Task.checkCancellation()
        switch plan {
        case .notCalculation:
            if followsCalculation {
                return publish("I couldn't recover that calculation reliably. Please send its expression and operation again.", onUpdate)
            }
            return try await tutor.reply(messages: messages, onStatus: onStatus, onUpdate: onUpdate)
        case .clarify(let message), .unsupported(let message):
            return publish(message, onUpdate)
        case .calculate(let request):
            guard request.isValid else {
                return publish("That calculation is outside the supported limits. Try a shorter expression or a smaller matrix.", onUpdate)
            }
            let result: MathCalculation
            onStatus(.calculating)
            do { result = try await calculator.calculate(request) }
            catch {
                try propagateCancellation(error)
                return publish("The on-device calculator couldn't finish. Please try again or simplify the calculation.", onUpdate)
            }
            try Task.checkCancellation()
            guard let calculated = result.answer(for: request) else {
                return publish("**Calculation unavailable**\n\n\(result.error ?? "The calculator did not return a complete result.")", onUpdate)
            }
            onUpdate(calculated)
            // Answer-only requests stop here: no explanatory inference or model switch.
            guard explanationStyle != .answerOnly else { return calculated }
            if request.operation == "integrate", explanationStyle == .steps {
                // Publish the answer first. Work has its own bounded job/cache entry, so
                // unavailable or interrupted work cannot discard a completed calculation.
                if let workCalculator = calculator as? any IntegralWorkCalculating {
                    onStatus(.calculating)
                    do {
                        let worked = try await workCalculator.calculateIntegralWork(request)
                        try Task.checkCancellation()
                        if worked.ok, worked.input == result.input, worked.exact == result.exact,
                           worked.latex == result.latex, let steps = MathWorkStep.render(worked.steps) {
                            return publish(calculated + "\n\n**Worked steps** · Calculated on device\n\n" + steps, onUpdate)
                        }
                    } catch { try propagateCancellation(error) }
                }
                return publish(calculated + "\n\n*Checked steps aren't available for this integral. The calculated answer above is retained.*", onUpdate)
            }
            var context = messages
            let recoveredRequest = followsCalculation ? "\nCalculation request: \(calculationQuestion.text)" : ""
            context.append(TutorMessage(role: .user, text: """
            Original user request: \(question.text)\(recoveredRequest)
            The app's calculator interpreted the request as \(request.label).
            Input: \(result.input ?? request.expression)
            Calculated result: \(result.exact ?? "")
            Conditions: \(result.note ?? "")
            \(explanationStyle == .brief ? "Describe the method; the answer is already displayed." : "Explain how to reach this exact answer using mathematical relationships.") \(explanationStyle.instructions)
            Use one coherent method, with no introduction or unsolicited follow-up question. The explanation is AI-generated, not verified by the calculator. Do not replace or contradict the supplied result. If the interpretation differs from the user's question or you cannot explain reliable steps, say so briefly.
            \(explanationStyle == .brief ? "Your reply must be only a plain-English method overview in two to four sentences. No equations, numbers, calculations, or worked steps." : "")
            """))
            let prefix = calculated + "\n\n**Explanation** · AI-generated\n\n"
            do {
                let update: @Sendable (String) -> Void = { onUpdate(prefix + $0) }
                let explanation: String
                if let focused = tutor as? any MathExplanationCompleting {
                    // The supplied input/result and latest request are sufficient; previous
                    // speculative explanations must not contaminate a new derivation.
                    explanation = try await focused.explainCalculation(messages: Array(context.suffix(1)), onStatus: onStatus, onUpdate: update)
                } else {
                    explanation = try await tutor.reply(messages: context, onStatus: onStatus, onUpdate: update)
                }
                try Task.checkCancellation()
                return prefix + explanation
            } catch {
                try propagateCancellation(error)
                return publish(calculated + "\n\n*The calculation completed, but its explanation could not be generated.*", onUpdate)
            }
        }
    }

    private func publish(_ text: String, _ onUpdate: @Sendable (String) -> Void) -> String {
        onUpdate(text); return text
    }
    private func propagateCancellation(_ error: Error) throws {
        if error is CancellationError || (error as? AgentTransportError) == .cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }
}
