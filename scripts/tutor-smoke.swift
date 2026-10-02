// Real bundled-model academic smoke test. No network or workspace tools.
import Foundation

struct AgentCompletion: Sendable {
    var assistantText: String
    var toolCalls: [AgentToolCall]
}
protocol AgentCompleting: Sendable {
    func complete(messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion
}

@main
struct TutorSmoke {
    static func main() async throws {
        let client = LocalAgentClient(modelURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        if CommandLine.arguments.contains("--planner") {
            let cases: [(String, String?)] = [
                ("Solve 2x+3=11", "solve"),
                ("What is 15% of 80?", "evaluate"),
                ("Integrate x squared from 0 to 1", "integrate"),
                ("Find RREF of [[1,1,2],[2,3,5]]", "rref"),
                ("Find the variance of 1,2,3", nil),
                ("Calculate the limit of sin(x)/x as x approaches 0", nil)
            ]
            for (question, operation) in cases {
                let plan = try await client.mathPlan(messages: [.init(role: .user, text: question)])
                print("QUESTION: \(question)\nPLAN: \(plan)\n")
                if let operation {
                    guard case .calculate(let request) = plan, request.operation == operation, request.isValid else {
                        throw NSError(domain: "MathPlannerSmoke", code: 1)
                    }
                } else {
                    guard case .clarify = plan else {
                        if case .unsupported = plan { continue }
                        throw NSError(domain: "MathPlannerSmoke", code: 2)
                    }
                }
            }
            let followup: [TutorMessage] = [
                .init(role: .user, text: "Find the variance of 1,2,3"),
                .init(role: .assistant, text: "Sample or population variance?"),
                .init(role: .user, text: "Population")
            ]
            let plan = try await client.mathPlan(messages: followup)
            guard case .calculate(let request) = plan, request.operation == "variance" else {
                throw NSError(domain: "MathPlannerSmoke", code: 3)
            }
            print("FOLLOW-UP: \(plan)\nAll math planner smoke checks passed.")
            return
        }
        let mathMode = CommandLine.arguments.contains("--math")
        let cases: [(String, [String])] = mathMode ? [
            ("Show the quadratic formula in a display equation and define a, b, and c briefly.", [#"\frac"#, #"\sqrt"#]),
            ("Show the integral of x squared with respect to x as a display equation, then explain the constant in one sentence.", [#"\int"#]),
            ("Show a 2 by 2 identity matrix using LaTeX bmatrix in a display equation. One brief sentence after it.", ["bmatrix"]),
            ("Show the population variance formula in a display equation and briefly explain its symbols.", [#"\sum"#])
        ] : [
            ("In one short sentence, state Newton's second law and explain its variables.", ["mass", "acceleration"]),
            ("In one sentence, what year was Magna Carta first sealed?", ["1215"]),
            ("Give one brief syntax tip each for C, Python, JavaScript and Lua. Four short bullets only.", ["python", "javascript", "lua"])
        ]
        for (question, expected) in cases {
            let start = Date()
            let answer = try await client.reply(messages: [TutorMessage(role: .user, text: question)], onUpdate: { _ in })
            print("QUESTION: \(question)\nANSWER: \(answer)\nSECONDS: \(Date().timeIntervalSince(start))\n")
            if mathMode {
                guard MathMessage.parse(answer).contains(where: { if case .equation = $0 { return true }; return false }) else {
                    throw NSError(domain: "TutorSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model did not produce a complete display equation"])
                }
            }
            guard expected.allSatisfy({ answer.lowercased().contains($0) }), !answer.contains("tool_calls") else {
                throw NSError(domain: "TutorSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Academic smoke check failed"])
            }
        }
        print(mathMode ? "All math model smoke checks passed." : "All academic model smoke checks passed.")
    }
}
