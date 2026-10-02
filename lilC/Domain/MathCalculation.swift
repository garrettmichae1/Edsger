import Foundation

struct MathRequest: Codable, Equatable, Sendable {
    let operation: String
    let expression: String
    var variable = "x"
    var lower = ""
    var upper = ""

    static let operations: Set<String> = ["evaluate", "simplify", "expand", "factor", "differentiate", "integrate", "solve", "determinant", "inverse", "mean", "variance"]
    var isValid: Bool {
        Self.operations.contains(operation) && !expression.isEmpty && expression.utf8.count <= 400 &&
        ["x", "y", "z", "t", "a", "b", "c", "n"].contains(variable) && lower.count <= 80 && upper.count <= 80
    }
    var label: String {
        switch operation {
        case "differentiate": "Derivative with respect to \(variable)"
        case "integrate": "Integral with respect to \(variable)"
        case "variance": "Population variance"
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
        guard ok, let input, let latex else { return nil }
        return "**\(request.label)** · Calculated on device with SymPy\n\nInput: \\(\(input)\\)\n\n\\[\(latex)\\]\n\n\(note ?? "")"
    }
}

protocol MathCalculating: Sendable {
    func calculate(_ request: MathRequest) async throws -> MathCalculation
}
protocol MathPlanning: Sendable {
    func mathRequest(messages: [TutorMessage]) async throws -> MathRequest?
}

/// Ordinary chat pays no planning cost. Ambiguous follow-ups are left to normal tutoring.
enum MathIntent {
    static func isCandidate(_ text: String) -> Bool {
        let lower = text.lowercased()
        let terms = ["calculate", "compute", "evaluate", "simplify", "expand", "factor", "differentiate", "derivative", "integrate", "integral", "solve", "determinant", "inverse", "mean of", "variance of"]
        let hasExpression = text.range(of: #"[0-9=^+*/]|\b(sin|cos|tan|log|exp)\s*\("#, options: .regularExpression) != nil
        return (hasExpression && terms.contains(where: lower.contains)) ||
            lower.range(of: #"^\s*(what is |what's )?[0-9][0-9\s.+*/^()%-]+\??\s*$"#, options: .regularExpression) != nil
    }
}

/// Composes existing tutoring with one bounded calculator request; no workspace tools.
struct CalculatingTutorClient: TutorCompleting {
    let tutor: any TutorCompleting
    let planner: any MathPlanning
    let calculator: any MathCalculating

    static let shared = Self(tutor: LocalAgentClient.shared, planner: LocalAgentClient.shared, calculator: LocalMathCalculator.shared)

    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let question = messages.last(where: { $0.role == .user }), MathIntent.isCandidate(question.text) else {
            return try await tutor.reply(messages: messages, onUpdate: onUpdate)
        }
        let request: MathRequest?
        do { request = try await planner.mathRequest(messages: messages) }
        catch {
            try Task.checkCancellation()
            return try await uncheckedReply(messages: messages, reason: "I couldn't prepare a local calculation.", onUpdate: onUpdate)
        }
        try Task.checkCancellation()
        guard let request else { return try await tutor.reply(messages: messages, onUpdate: onUpdate) }
        guard request.isValid else {
            return try await uncheckedReply(messages: messages, reason: "This calculation is outside the supported limits.", onUpdate: onUpdate)
        }
        let result = try await calculator.calculate(request)
        try Task.checkCancellation()
        guard let verified = result.answer(for: request) else {
            return try await uncheckedReply(messages: messages, reason: result.error ?? "The local calculation did not complete.", onUpdate: onUpdate)
        }
        onUpdate(verified)
        var context = messages
        context.append(TutorMessage(role: .user, text: """
        The app's local SymPy calculator interpreted my request as \(request.label), input \(result.input ?? request.expression).
        It returned: \(result.exact ?? ""). LaTeX: \(result.latex ?? ""). Conditions: \(result.note ?? "").
        The app already displayed that input, result, and conditions. Briefly explain the result in relation to my question. Do not repeat it or claim the explanation is verified. If the interpretation differs from my question, say so. Do not claim to have run code or accessed files.
        """))
        do {
            let explanation = try await tutor.reply(messages: context) { onUpdate(verified + "\n\n" + $0) }
            return verified + "\n\n" + explanation
        } catch {
            try Task.checkCancellation()
            return verified + "\n\n*The calculation completed, but its explanation could not be generated.*"
        }
    }

    private func uncheckedReply(messages: [TutorMessage], reason: String, onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        let prefix = "*Not checked by SymPy: \(reason)*\n\n"
        var context = messages
        context.append(TutorMessage(role: .user, text: "The local calculator did not verify this request. Explain cautiously and do not claim a verified or computed result."))
        let answer = try await tutor.reply(messages: context) { onUpdate(prefix + $0) }
        return prefix + answer
    }
}
