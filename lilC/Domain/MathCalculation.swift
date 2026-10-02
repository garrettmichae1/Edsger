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

    static func unavailable(_ reason: String) -> Self { .init(ok: false, error: reason) }
    func answer(for request: MathRequest) -> String? {
        guard ok, let input, !input.isEmpty, let latex, !latex.isEmpty, let exact, !exact.isEmpty else { return nil }
        return "**\(request.label)** · Calculated on device\n\nInterpreted input:\n\\[\(input)\\]\n\nResult:\n\\[\(latex)\\]\n\n\(note ?? "")"
    }
}

protocol MathCalculating: Sendable {
    func calculate(_ request: MathRequest) async throws -> MathCalculation
}

/// Calculator results are published before explanation; the model never supplies the result card.
struct CalculatingTutorClient: TutorCompleting {
    let tutor: any TutorCompleting
    let planner: any MathPlanning
    let calculator: any MathCalculating

    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        guard let question = messages.last(where: { $0.role == .user }), MathIntent.isCandidate(messages) else {
            return try await tutor.reply(messages: messages, onUpdate: onUpdate)
        }
        let plan: MathPlan
        do {
            if let request = MathIntent.directArithmetic(question.text) { plan = .calculate(request) }
            else { plan = try await planner.mathPlan(messages: messages) }
        } catch {
            try propagateCancellation(error)
            return publish("I couldn't interpret that calculation reliably. Please try one calculation at a time, with its expression or equation and the operation you want.", onUpdate)
        }
        try Task.checkCancellation()
        switch plan {
        case .notCalculation:
            return try await tutor.reply(messages: messages, onUpdate: onUpdate)
        case .clarify(let message), .unsupported(let message):
            return publish(message, onUpdate)
        case .calculate(let request):
            guard request.isValid else {
                return publish("That calculation is outside the supported limits. Try a shorter expression or a smaller matrix.", onUpdate)
            }
            let result: MathCalculation
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
            // A completed numeric expression needs no model pass. This also works with no model asset.
            if MathIntent.directArithmetic(question.text) != nil { return calculated }
            var context = messages
            context.append(TutorMessage(role: .user, text: """
            The app's calculator interpreted the request as \(request.label).
            Input: \(result.input ?? request.expression)
            Calculated result: \(result.exact ?? "")
            Conditions: \(result.note ?? "")
            The app has already displayed the interpreted input, result, and conditions. Explain briefly, or give steps if requested. The explanation is AI-generated, not verified by the calculator. Do not replace or contradict its result. If the interpretation does not match the original question, explicitly say so. Never claim that every step was checked. Do not claim file access or code execution.
            """))
            let prefix = calculated + "\n\n**Explanation** · AI-generated\n\n"
            do {
                let explanation = try await tutor.reply(messages: context) { onUpdate(prefix + $0) }
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
