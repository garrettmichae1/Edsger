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


## October 2 follow-up: greedy grammar checking and earlier review

This pass implements two changes without changing the model, grammar, response budgets, tool permissions, or inference-context clearing:

- `GreedyGrammarSampler` first selects the unconstrained greedy candidate and checks that single token against the grammar. If valid, it advances the grammar exactly once; if invalid, it falls back to the original full-vocabulary grammar-first greedy selection. Both paths use reusable sampler-chain buffers. The IDE agent and math planner use it; ordinary text chat already has no grammar. This follows the rejection-sampling approach in the pinned llama.cpp [common sampler](https://github.com/ggml-org/llama.cpp/blob/b11306/common/sampling.cpp).
- After a successful mutation batch, `AgentSession` adds the existing review instruction before the next model call. Previously it waited for a no-tool answer, discarded that answer, and then asked for review. Review can still read, repair, run, and continue through the normal bounded tool loop. Failed writes alone do not trigger review. The instruction stays in the active turn, and token budgeting explicitly excludes it as a new user-task boundary so the original request, snapshot, and tool history stay together.

An attempted system-message placement was rejected during real-model testing: the model completed a declaration-only header without repairing it. The shipped placement retains the original latest-user-instruction behavior. Faster but incomplete output was not counted as success.

### Measurements

Environment: Linux x86-64 CPU backend, Swift 6.0.3 optimized build, unchanged Qwen3.5-4B Q4_K_M and llama.cpp b11306. These are single exploratory runs, not iPhone/Metal measurements or a promised device speedup. Both agent runs include a fresh model load (about 2 seconds).

The task was: `Create math.h with a complete function int square(int n) that returns n*n. Do not run it.` The harness supplied a small C project description and emulated write/read/replace tool results using a temporary header. This isolates inference and the review flow; it does not measure the real iOS editor or PicoC. The final header was independently compiled with strict host C warnings and checked for square(0), square(7), square(-3), and repeated inclusion.

| Metric | Before | After |
| --- | ---: | ---: |
| Whole task | 62.35 s | 46.83 s |
| Model calls | 5 | 4 |
| Generated tokens | 168 | 153 |
| Prompt processing | 42.27 s | 34.07 s |
| Generation | 18.07 s | 10.84 s |

Both runs first wrote a declaration and then repaired it. The optimized sequence retains read, repair, and final confirmation while eliminating the discarded answer. Total elapsed time fell about 25% in this sample. Baseline instrumentation also ran the candidate sampler for equivalence, adding approximately 0.16 seconds; correcting for it leaves the rounded improvement unchanged. Timing variation and differences between CPU and Metal mean this percentage must not be treated as a phone benchmark.

The baseline probe measured 5.13 seconds of grammar-first sampling versus 0.16 seconds for candidate checking on identical logits, with the same 168 selected tokens. That is a component measurement, not a whole-task speedup. Raw traces are in `Docs/benchmarks/agent-latency-2026-10-02-{baseline,optimized}.txt`.

### Validation and reproduction

- Production sampler regression: 198 identical decisions against grammar-first greedy, including 98 deliberately rejected candidates, escaped strings, Unicode, four-call batches, math plans, EOS, and fresh grammar state.
- Production `AgentSession` compiled and ran against host workspace/settings doubles: immediate review after successful writes; failed writes do not trigger review; failed-run output and the original task remain available; repairs proceed; ordinary answers use one call.
- iOS unit assertions were updated for earlier review, repair, and token-budget boundaries. They still need execution in Xcode; the host doubles do not validate iOS file/runtime behavior.
- Optimized Swift 6 compilation and actual model planning/repair passed on the host. No physical iPhone or Xcode build was available for this pass.

On a Mac with the pinned assets:

```sh
scripts/test-local-sampler.sh
scripts/test-local-agent.sh --snapshot --header-only
scripts/test-local-agent.sh --snapshot --binary-search
```

The header-only smoke command independently compiles and checks the generated function. Its project prompt differs from the exploratory trace, so use it for repeatable correctness/performance comparisons rather than expecting the exact recorded timings. For device measurements, use the existing `app.lilc` / `AgentPerformance` logs and record several warm runs plus a separate cold run. Context reuse remains a later, separately validated change because this hybrid model has recurrent state; removing the memory clear alone is unsafe.

## October 3 follow-up: prompt reuse and generation experiments

See [the further latency investigation](PROMPT_REUSE_INVESTIGATION.md) for four exact-output native state-reuse comparisons, CPU runtime measurements, and a speculative-decoding probe. Prompt processing fell 47–87% on cache hits in these host-only samples. The speculative code response failed output equivalence and is not counted as a speedup. These are investigation artifacts; app inference behavior remains at the October 2 implementation pending cache integration and iPhone validation.
