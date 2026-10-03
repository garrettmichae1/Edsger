import Foundation

struct TutorMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    var id = UUID()
    let role: Role
    var text: String
    var document: ChatDocumentReference?
    var sources: [ChatDocumentSource]?
}

struct ChatDocumentReference: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: String
    let byteCount: Int
    let characterCount: Int
    let pageCount: Int?
    let preview: String
    let importedAt: Date
    let note: String
}

struct ChatDocumentSource: Identifiable, Codable, Equatable, Sendable {
    let id: Int
    let documentID: UUID
    let name: String
    let location: String
    let text: String
}

/// Optional capability: existing clients and test doubles retain their original path.
protocol DocumentTutorCompleting: TutorCompleting {
    func replyWithDocuments(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
                            onSources: @escaping @Sendable ([ChatDocumentSource]) async -> Void,
                            onUpdate: @escaping @Sendable (String) -> Void) async throws -> String
}

struct TutorConversation: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var messages: [TutorMessage] = []
    var updatedAt = Date()
    // Optional so conversation files written before pinning still decode unchanged.
    var pinnedAt: Date?
    var isPinned: Bool { pinnedAt != nil }

    static func historyOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if let left = lhs.pinnedAt, let right = rhs.pinnedAt, left != right { return left > right }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    var title: String {
        let first = messages.first { $0.role == .user }?.text ?? "New chat"
        return String(first.replacingOccurrences(of: "\n", with: " ").prefix(70))
    }
}

protocol TutorCompleting: Sendable {
    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String
    func reply(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
               onUpdate: @escaping @Sendable (String) -> Void) async throws -> String
}

extension TutorCompleting {
    func reply(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
               onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        onStatus(.generatingResponse)
        return try await reply(messages: messages, onUpdate: onUpdate)
    }
}

typealias GenerationStatusHandler = @Sendable (GenerationStatus) -> Void

enum GenerationStatus: Sendable, Equatable {
    case waiting, loadingModel, preparingPrompt, generatingResponse, planningCalculation, calculating, readingDocument

    var label: String {
        switch self {
        case .waiting: "Waiting for the on-device engine…"
        case .loadingModel: "Loading the on-device model…"
        case .preparingPrompt: "Reading your request…"
        case .generatingResponse: "Generating a response…"
        case .planningCalculation: "Interpreting your calculation…"
        case .calculating: "Calculating on your device…"
        case .readingDocument: "Finding passages in your file…"
        }
    }
}

/// Geometry changes caused by growing answers must not be mistaken for a user scrolling away.
struct TranscriptScrollState {
    private(set) var followsLatest = true
    private(set) var isInteracting = false
    private(set) var isNearBottom = true
    private(set) var hasUnreadContent = false

    var shouldFollow: Bool { followsLatest && !isInteracting }

    mutating func beginInteraction() {
        isInteracting = true
        followsLatest = false
    }
    mutating func updateDistanceFromBottom(_ distance: Double) {
        isNearBottom = distance <= 80
        if isInteracting { followsLatest = isNearBottom }
        if isNearBottom { hasUnreadContent = false }
    }
    mutating func endInteraction() {
        // Programmatic scrolling and viewport resizing also finish in idle.
        // Only a real gesture may change the user's follow preference here.
        guard isInteracting else { return }
        isInteracting = false
        followsLatest = isNearBottom
        if followsLatest { hasUnreadContent = false }
    }
    mutating func contentChanged() -> Bool {
        if !shouldFollow && !isNearBottom { hasUnreadContent = true }
        return shouldFollow
    }
    mutating func showLatest() {
        followsLatest = true
        hasUnreadContent = false
    }
}

enum TutorPrompt {
    static let instructions = #"""
    You are EDSGER, a friendly offline academic tutor inside lilC. Your specialty is teaching C, Python, JavaScript, and Lua, and you also help with history, physics, mathematics, writing, and other academic subjects.
    Answer the user's actual question directly. Explain clearly at their level, use concrete examples, and break complex ideas into small steps. Ask a brief clarifying question when necessary; do not force a quiz or a course onto every answer. For practice or guided learning, scaffold the task and invite the learner to try the next step. Be encouraging without condescension.
    Keep the first answer concise unless the learner requests detail. Follow an explicitly requested sentence or bullet count; do not add an unsolicited follow-up question to a complete factual answer. Use Markdown and fenced code blocks for examples. Write mathematical notation using LaTeX: use \( ... \) for short inline expressions and \[ ... \] for standalone equations and worked steps. Use this for algebra, calculus, linear algebra, probability, statistics, and science whenever mathematical notation helps. Use \frac, \sqrt, subscripts, superscripts, \sum, \int, and Greek commands as appropriate. Use bmatrix or pmatrix for matrices, aligned for multi-step equations, and cases for piecewise definitions. Put each important equation on its own display block and keep equations short enough for a phone screen. Always close math delimiters and braces. Keep explanations outside math delimiters. Do not put math in code fences; reserve code fences for programming examples. Use standard commands rather than custom macros, packages, full LaTeX documents, or equation numbering. Explain what symbols mean in ordinary words. You may write example code in chat, but you have no tools and cannot read, edit, run, or delete project files. Never claim you performed those actions. Do not output tool calls or JSON envelopes.
    You run entirely on the device, without internet browsing or current information. Be honest when uncertain, distinguish established facts from interpretations, and never invent citations, quotations, sources, or current facts. Use units in science and mathematics. The app may supply a separately calculated result. Only that explicit result comes from the calculator; your explanations and worked steps are not calculator-verified. Never claim a calculation was checked or executed unless the app supplied its result. Give educational explanations rather than professional medical, legal, or financial advice.
    C examples for this app use PicoC: simple complete functions, no external libraries or function pointers. Python uses CPython 3.14 with local modules and the bundled standard library, no pip or GUI. JavaScript uses JavaScriptCore console.log(), input(), and local CommonJS require(), without Node.js, DOM, npm, or timers. Lua uses Lua 5.5 with print(), io.read(), and local source modules, without native modules or shell commands. Lua local variables have lexical block scope, not only function scope. These are app-specific restrictions; explain standard language features when that is what the learner asks about.
    """#

    static func make(messages: [TutorMessage]) -> String {
        var text = "<|im_start|>system\n\(instructions)<|im_end|>\n"
        for message in messages where !message.text.isEmpty {
            let safe = message.text.replacingOccurrences(of: "<|", with: "< |")
            text += "<|im_start|>\(message.role.rawValue)\n\(safe)<|im_end|>\n"
        }
        return text + "<|im_start|>assistant\n<think>\n</think>\n"
    }
}
