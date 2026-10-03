// Verify optimized selection against grammar-first greedy using controlled logits.
// Tests real model vocabulary/token boundaries; no generated code is executed here.
import Foundation
import llama

struct AgentCompletion: Sendable { var assistantText: String; var toolCalls: [AgentToolCall] }
protocol AgentCompleting: Sendable {
    func complete(messagesJSON: Data, toolsJSON: Data) async throws -> AgentCompletion
}

@main struct SamplerSmoke {
    static func main() throws {
        if CommandLine.arguments.count > 2 { ggml_backend_load_all_from_path(CommandLine.arguments[2]) }
        llama_backend_init()
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = 0 // Vocabulary correctness test, not a speed benchmark.
        guard let model = llama_model_load_from_file(CommandLine.arguments[1], parameters) else { fatalError("Model missing") }
        defer { llama_model_free(model) }
        var options = llama_context_default_params()
        options.n_ctx = 512; options.n_batch = 32; options.n_ubatch = 32
        guard let context = llama_init_from_model(model, options) else { fatalError("Context failed") }
        defer { llama_free(context) }
        let vocab = llama_model_get_vocab(model)
        let count = Int(llama_vocab_n_tokens(vocab))
        func tokenize(_ text: String) -> [llama_token] {
            var tokens = [llama_token](repeating: 0, count: 4096)
            let n = text.withCString { llama_tokenize(vocab, $0, Int32(strlen($0)), &tokens, 4096, false, false) }
            precondition(n > 0 && n < 4096)
            return Array(tokens.prefix(Int(n)))
        }
        var seed = tokenize("Hello")[0]
        precondition(llama_decode(context, llama_batch_get_one(&seed, 1)) == 0)
        llama_synchronize(context)
        let logits = llama_get_logits_ith(context, -1)!
        let eos = llama_vocab_eos(vocab)
        precondition(eos >= 0)
        let requests = [
            #"{"message":"Done","tool_calls":[]}"#,
            #"{"message":"Writing café α","tool_calls":[{"name":"write_file","arguments":{"path":"main.c","contents":"int main(void) { puts(\"hi\"); return 0; }\n// backslash \\"}}]}"#,
            #"{"message":"Inspecting","tool_calls":[{"name":"read_file","arguments":{"path":"a.c"}},{"name":"read_file","arguments":{"path":"b.c"}},{"name":"list_files","arguments":{}},{"name":"read_output","arguments":{}}]}"#
        ]
        let plans = [
            #"{"kind":"none"}"#,
            #"{"kind":"clarify","message":"Sample or population?"}"#,
            #"{"kind":"calculate","request":{"operation":"integrate","expression":"x^2","variable":"x","lower":"0","upper":"1"}}"#,
            #"{"kind":"calculate","request":{"operation":"rref","expression":"[[1,2],[3,4]]","variable":"x","lower":"","upper":""}}"#
        ]
        var compared = 0, fallbacks = 0
        for (grammarText, texts) in [(LocalAgentClient.responseGrammar, requests), (MathPlannerPrompt.grammar, plans)] {
            for text in texts {
                // Fresh grammar state for each request, as in production.
                let optimized = try GreedyGrammarSampler(vocab: vocab, grammar: grammarText)
                let baseline = llama_sampler_chain_init(llama_sampler_chain_default_params())
                defer { llama_sampler_free(baseline) }
                llama_sampler_chain_add(baseline, llama_sampler_init_grammar(vocab, grammarText, "root"))
                llama_sampler_chain_add(baseline, llama_sampler_init_greedy())
                for (index, target) in (tokenize(text) + [eos]).enumerated() {
                    for i in 0..<count { logits[i] = -100 }
                    logits[Int(target)] = 2
                    // Force rejection of premature EOS on alternate steps, and acceptance
                    // of ordinary tokens on the others. Ending EOS must still be accepted.
                    if index % 2 == 0 && target != eos { logits[Int(eos)] = 3 }
                    let reference = llama_sampler_sample(baseline, context, -1)
                    let selected = optimized.sample(context: context)
                    precondition(reference == target && selected == reference, "Token selection differs")
                    compared += 1
                }
                fallbacks += optimized.fallbackCount
                if grammarText == LocalAgentClient.responseGrammar { _ = try LocalAgentClient.parseResponse(text) }
                else { _ = try MathPlan.parse(Data(text.utf8)) }
            }
        }
        precondition(fallbacks > 0)
        print("PASS: \(compared) identical token decisions, \(fallbacks) forced fallback decisions; escaped text, Unicode, batched tools, math plans, EOS, and fresh state.")
    }
}
