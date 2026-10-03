// Real model answers with the production bounded evidence prompt. Not an accuracy benchmark.
import Foundation
#if os(Linux)
import llama
#endif

@main struct DocumentModelSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Pass Mini and Standard GGUF paths") }
        #if os(Linux)
        if let path = ProcessInfo.processInfo.environment["LLAMA_BACKEND_PATH"] { ggml_backend_load_all_from_path(path) }
        #endif
        let engine = LocalAgentClient(modelURL: URL(fileURLWithPath: CommandLine.arguments[2]),
                                      miniModelURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let reference = ChatDocumentReference(id: UUID(), name: "contract.txt", kind: "txt", byteCount: 80,
            characterCount: 80, pageCount: nil, preview: "Contract", importedAt: Date(), note: "Plain text only.")
        let document = ExtractedDocument(reference: reference, sections: [
            .init(location: "Paragraph 1", text: "The cancellation fee is 125 dollars. The renewal deadline is March 17.")
        ])
        for model in [ChatModel.mini, .standard] {
            let bound = ModelBoundChatClient(model: model, engine: engine)
            for question in ["What is the cancellation fee? Answer in one sentence with a source citation.",
                             "What is the renewal deadline? Answer in one sentence with a source citation."] {
                let sources = DocumentRetrieval.sources(document: document, question: question)
                let prompt = try DocumentRetrieval.prompt(question: question, sources: sources, note: reference.note)
                let answer = try await bound.reply(messages: [.init(role: .user, text: prompt)], onUpdate: { _ in })
                let expected = question.contains("fee") ? "125" : "March 17"
                guard answer.contains(expected), answer.contains("[1]") else { throw SmokeFailure.answer(model.rawValue, answer) }
                let timing = await engine.lastTiming
                print("PASS \(model.rawValue): \(answer)\nHOST TIMING: firstToken=\(timing.firstTokenSeconds ?? -1), total=\(timing.totalSeconds)")
            }
        }
        await engine.unloadMiniModel()
    }
    enum SmokeFailure: Error { case answer(String, String) }
}
