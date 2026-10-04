import Foundation

extension ChatModelStore {
    static let shared = ChatModelStore(files: LocalModelFiles(), runtime: LocalAgentClient.shared)
}

/// Captures the chat choice once. Keep the proven Qwen math interpreter for both choices.
struct SelectedChatClient: DocumentTutorCompleting {
    static let shared = SelectedChatClient()
    func reply(messages: [TutorMessage], onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try await reply(messages: messages, onStatus: { _ in }, onUpdate: onUpdate)
    }
    func reply(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
               onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        try await replyWithDocuments(messages: messages, onStatus: onStatus, onSources: { _ in }, onUpdate: onUpdate)
    }
    func replyWithDocuments(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
                            onSources: @escaping @Sendable ([ChatDocumentSource]) async -> Void,
                            onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        let providers = await BYOKStore.shared
        try await providers.beginRun()
        let mobile = await MobileAgentStore.shared
        await mobile.beginRun()
        do {
            let result: String
            if let choice = await providers.effectiveChatChoice {
                let bound = BYOKChatClient(agent: try await providers.client(for: choice))
                let ordinary = CalculatingTutorClient(tutor: bound, planner: bound, calculator: LocalMathCalculator.shared)
                let client = DocumentTutorClient(tutor: ordinary, documentTutor: bound, documents: ChatDocumentStore.shared)
                result = try await client.replyWithDocuments(messages: messages, onStatus: onStatus, onSources: onSources, onUpdate: onUpdate)
            } else if await mobile.usesCloudForChat {
                do {
                    let bound = BYOKChatClient(agent: await mobile.client())
                    let ordinary = CalculatingTutorClient(tutor: bound, planner: bound, calculator: LocalMathCalculator.shared)
                    let client = DocumentTutorClient(tutor: ordinary, documentTutor: bound, documents: ChatDocumentStore.shared)
                    // Buffer cloud text until the entire read-only Chat turn succeeds.
                    result = try await client.replyWithDocuments(messages: messages, onStatus: onStatus, onSources: onSources, onUpdate: { _ in })
                    onUpdate(result)
                } catch let error as MobileAgentError where error.usesLocalNext {
                    result = try await localReply(messages: messages, onStatus: onStatus, onSources: onSources, onUpdate: onUpdate)
                }
            } else {
                result = try await localReply(messages: messages, onStatus: onStatus, onSources: onSources, onUpdate: onUpdate)
            }
            await providers.endRun()
            await mobile.endRun()
            return result
        } catch {
            await providers.endRun()
            await mobile.endRun()
            throw error
        }
    }

    private func localReply(messages: [TutorMessage], onStatus: @escaping GenerationStatusHandler,
                            onSources: @escaping @Sendable ([ChatDocumentSource]) async -> Void,
                            onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        let store = await ChatModelStore.shared
        let model = try await store.beginReply()
        do {
            let bound = ModelBoundChatClient(model: model)
            let ordinary = CalculatingTutorClient(tutor: bound, planner: bound, calculator: LocalMathCalculator.shared)
            let client = DocumentTutorClient(tutor: ordinary, documentTutor: bound, documents: ChatDocumentStore.shared)
            let result = try await client.replyWithDocuments(messages: messages, onStatus: onStatus, onSources: onSources, onUpdate: onUpdate)
            await store.endReply()
            return result
        } catch {
            await store.endReply()
            throw error
        }
    }
}
