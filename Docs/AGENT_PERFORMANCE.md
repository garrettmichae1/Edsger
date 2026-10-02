# On-device agent performance pass — October 1, 2026

Goal: bring small edit-and-test requests toward 20–30 seconds while keeping the working agent's reliability. The screenshots establish successful behavior, not measured stage timings. No physical iPhone was benchmarked during this pass.

## Findings and implemented changes

`LocalAgentClient` keeps its model resident already, uses Metal on devices, and runs synchronous inference inside a dedicated actor rather than the main UI actor. Merely adding another background queue does not remove a known bottleneck.

Every completion clears llama memory and decodes the entire prompt again. Each extra model round trip therefore costs both prompt processing and generation. Tool execution is sequential; edits must finish before code can be tested.

Changes made in this pass:

- Supply the selected file's current contents with the active request when it is at most 6,000 UTF-8 bytes. The snapshot counts as inspection, eliminating a separate read/rejected-write turn when the model uses it. Larger files and other files retain the existing read-before-mutation path.
- Refresh inspection state after the agent's own successful write, replacement, or deletion. Previously, a second edit to the same file could be rejected despite the agent knowing exactly what it just wrote. The live contents comparison remains in place and still catches intervening user edits.
- Ask for a short progress sentence and combined implementation/test edits. Explicitly permit the existing maximum of four ordered calls, including write then run. This is a prompt preference, not a guarantee of fewer steps.
- Record model loading, prompt decoding, response generation, total completion duration, and token counts. View device logs under subsystem `app.lilc`, category `AgentPerformance`. These logs contain timings and counts, not source or conversation text. The standalone smoke test prints the same measurements.
- Extend the real-model harness with optional snapshots and a binary-search edit/run scenario. Independently compile and verify found, absent, empty input, first element, and last element behavior.

The grammar, model, 3,072-token response budget, cancellation checks, project restrictions, and mandatory bounded completion review are retained. The review is valuable: the header smoke case still needed it to repair a prototype into a function body.

## Measurements and limits

Hardware: Apple M5 Mac, bundled Qwen3.5-4B Q4_K_M and pinned llama.cpp b11306 with Metal. The standalone harness executes generated code with host Clang, not iPhone PicoC. The app regression suite separately exercises PicoC and agent orchestration. These are exploratory single runs, not medians or device latency guarantees.

The comparable binary-search baseline completed in 29 seconds and five completions; the optimized run completed in 22 seconds and four completions (about 24% lower elapsed time in this single sample). Both passed the same independent behavioral checks. Its first completion combined a full implementation, test cases, and a run call. Approximately 18.3 seconds went to generation, 3.8 seconds to prompt decoding, and the remainder to tools/overhead. It generated 397 tokens across those completions. The model was already loaded by earlier scenarios.

A simple greeting edit initially took 10 seconds with the old behavior and 7 seconds with snapshots and the new prompt. This early comparison had different model-load conditions. The header scenario took about 15 seconds after this change versus 12 seconds in the initial baseline: prompting does not improve every task, and unnecessary runs can erase savings. Do not advertise a universal speedup from these samples.

The simulator regression suite passed 127 tests (140 executions including parameterized cases), including new checks for successive edits without redundant reads, rejection of intervening user edits, and inspection of oversized files.

Reproduce the optimized standalone run:

```sh
scripts/test-local-agent.sh --snapshot --binary-search
```

Without `--snapshot`, the harness retains the original read/inspection behavior. It still uses the current model prompt, so that flag alone is not a complete old/new comparison. The comparison performed here compiled an instrumented copy of the original prompt and disabled snapshots. Filtered timings are stored in `Docs/benchmarks/`.

## Next engineering options, in priority order

1. **Measure the phone with the new logs.** Repeat the same binary-search request from the same starter source and a new conversation. Record five warm runs and a separate first-use run, phone model, power mode, and thermal state. Compare correctness, median and slowest completion, number of model calls, total output tokens, and prompt/generation time. The 20–30-second target should apply to a named device and task size.
2. **Reduce review overhead without removing review.** The current loop generates a proposed final answer, discards it, and requests another review. A future explicit finish-and-review state could review immediately after the last successful edit/run and avoid generating that discarded answer. Preserve repair behavior for incomplete functions; test failed runs and multi-file tasks before adopting it.
3. **Reuse inference state across tool turns.** Potentially valuable for longer files/conversations. Preserve the exact token prefix actually decoded and append tool results; the current JSON reserialization changes assistant tokens and prevents naive reuse. Qwen3.5 also has recurrent state, so prefix truncation must be supported or fall back to clearing memory. Validate cancellation, context eviction, project switches, changed files, and cold-versus-cached output equivalence before shipping. Simply deleting `llama_memory_clear` is incorrect. Upstream has documented Qwen3.5 cache-reuse edge cases: https://github.com/ggml-org/llama.cpp/issues/20643.
4. **Benchmark a smaller model as an optional fast mode.** Potentially a larger generation-speed improvement than caching, but do not replace the working 4B model until the smaller model passes implementation, exact edits, repair, and PicoC tests. Compare total task time including retries, not just tokens per second.
5. **Investigate speculative decoding after profiling.** This is the meaningful version of a second model: a small draft proposes tokens that the main model verifies in batches. Upstream documentation describes draft-model and no-extra-model n-gram approaches: https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md. Compatibility with this exact hybrid model, pinned runtime, JSON grammar, and iPhone memory budget needs a prototype. Current upstream features are not automatically present in b11306. Acceptance rate and verification cost determine whether it helps.

A second independent agent/process is not the preferred first change. It would compete for the same device memory bandwidth and GPU while the write→run→inspect chain remains dependent. Running two full models is not expected to halve single-request latency. A remote inference option could change that hardware limit, but it changes the offline product's privacy, connectivity, and operating-cost model and was not introduced here.

A useful feasibility check is `total ≈ loading + prompt processing + generated tokens / generation rate + tools`. At 397 output tokens, a phone generating 10 tokens/second already needs nearly 40 seconds for generation alone. Achieving 20–30 seconds on that phone would require fewer output tokens, a faster model/runtime, or verified speculation—not merely moving work to another queue.
