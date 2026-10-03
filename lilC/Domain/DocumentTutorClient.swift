import Foundation

protocol ChatDocumentReading: Sendable {
    func read(_ id: UUID) async throws -> ExtractedDocument
}

/// Document context is bounded independently of conversation history and the normal math/chat path.
struct DocumentTutorClient: DocumentTutorCompleting {
    let tutor: any TutorCompleting
    let documentTutor: any TutorCompleting
    let documents: any ChatDocumentReading

    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try await replyWithDocuments(messages: messages, onStatus: { _ in }, onSources: { _ in }, onUpdate: onUpdate)
    }
    func reply(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
               onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try await replyWithDocuments(messages: messages, onStatus: onStatus, onSources: { _ in }, onUpdate: onUpdate)
    }
    func replyWithDocuments(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
                            onSources: @escaping @Sendable ([ChatDocumentSource]) async -> Void,
                            onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let attachmentIndex = messages.lastIndex(where: { $0.role == .user && $0.document != nil }),
              let reference = messages[attachmentIndex].document,
              let question = messages.last(where: { $0.role == .user }) else {
            return try await tutor.reply(messages: messages, onStatus: onStatus, onUpdate: onUpdate)
        }
        guard question.text.utf8.count <= DocumentLimits.questionBytes else { throw DocumentQuestionError.tooLong }
        onStatus(.readingDocument)
        let document = try await documents.read(reference.id)
        try Task.checkCancellation()
        let previous = messages[attachmentIndex...].filter { $0.role == .user && $0.id != question.id }.last?.text ?? ""
        let sources = DocumentRetrieval.sources(document: document, question: question.text, previousQuestion: previous)
        await onSources(sources)
        try Task.checkCancellation()
        guard !sources.isEmpty else {
            let answer = "I couldn't find a matching passage in \(reference.name). Try a specific term from the file, ask for an overview, or attach the file you want to discuss."
            onUpdate(answer)
            return answer
        }
        // Only this file's recent conversation can resolve follow-ups; it is not document evidence.
        let prior = messages[attachmentIndex...].dropLast().suffix(2).map {
            $0.role.rawValue + ": " + DocumentRetrieval.bytePrefix($0.text, limit: 500)
        }.joined(separator: "\n")
        let prompt = try DocumentRetrieval.prompt(question: question.text, sources: sources, note: document.reference.note, previous: prior)
        return try await documentTutor.reply(messages: [.init(role: .user, text: prompt)], onStatus: onStatus, onUpdate: onUpdate)
    }
}

private enum DocumentQuestionError: LocalizedError {
    case tooLong
    var errorDescription: String? { "For file questions, use a focused question under 2,000 bytes." }
}
