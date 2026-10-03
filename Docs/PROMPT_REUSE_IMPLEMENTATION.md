# Automatic prompt reuse — implementation and validation

## What changed

IDE code generation, text chat, and math planning now share one prompt-processing path. It can restore an exact previously processed prompt prefix instead of decoding those tokens again. This optimizes prompt processing and time to first output; it does not claim to accelerate each generated token.

`PromptReuseCache` retains one native sequence checkpoint in memory. That checkpoint contains the model's attention and recurrent state, bound to the lifetime of its model/context. It contains prompt tokens only, never generated output. Every reuse compares the complete saved token prefix against the current, freshly rendered and tokenized prompt. If the prefix differs, the context changes, or restoring the state fails, the client clears live inference memory and decodes the full current prompt.

Checkpoint selection uses the model tokenizer's actual `<|im_end|>` token. It finds the last completed message, rounds down to the existing 256-token batch boundary, and caps the prefix at 1,024 tokens. At least one new prompt token must be decoded after restoration, so the sampler always receives fresh logits. Generated assistant JSON can therefore be reserialized normally without assuming those generated tokens form the next input prefix. Prompt contents, grammar, response budgets, review behavior, and the model remain unchanged.

## Resource and failure behavior

- One checkpoint; at most 96 MiB for native state plus retained token storage. Check the native state's required size before allocating. Release the previous entry before allocating its replacement. A larger state skips capture and leaves inference available.
- On iOS, query current app memory headroom before reuse and allocation using Apple's [`os_proc_available_memory`](https://developer.apple.com/documentation/os/os_proc_available_memory). Require a 256 MiB reserve beyond the proposed allocation. Low headroom evicts/skips the cache; a later request can retry when memory is available. This is advisory, not a guarantee against termination.
- A successful capture is published only after a complete native copy and a cancellation check. Interrupted processing, failed decoding, and unsuccessful inference clear reusable state. A failed restore clears any partially restored live state before full processing.
- An iOS memory warning sets a thread-safe signal immediately, even while synchronous inference occupies its actor. Inference checks it between prompt batches and generated tokens. An actor task also evicts an idle checkpoint. Caching stays disabled for that client/session after a warning; it does not repeatedly allocate again under pressure.
- Saved state remains in process memory and is never written to disk. Model/context replacement cannot reuse a previous entry. Every sampler is still created separately for each response.
- GPU work is synchronized at checkpoint and final prompt boundaries before recording phase durations. Timing therefore includes completed prompt work rather than only GPU submission.

The 96 MiB limit is an engineering bound, not proof that every supported iPhone has that much spare memory. Physical-device peak-memory and thermal measurements remain necessary. A single entry can miss when chat and math planning alternate; this deliberate tradeoff bounds memory before considering a multi-entry policy.

## Measurements

Production-client baseline/cached results and the automatic comparison summary are stored with this change under `Docs/benchmarks/prompt-reuse-implementation-2026-10-03/`. The baseline uses the same client and disables the cache with a zero-byte limit. This isolates prompt reuse from model, prompt, grammar, and orchestration changes.

The test corpus includes IDE write/review/repair prompts, a project change, chat follow-ups, Unicode, history truncation, math planning, and returning from math to chat. Chat follow-ups are repeated five times per configuration. The cached run also cancels during streamed generation, verifies recovery, and triggers the production memory-pressure path. The comparator fails on changed outputs, token-count discrepancies, wrong cache accounting, unexpected reuse across changed context, memory-budget violations, or failed recovery before reporting latency.

Environment: Linux x86-64 CPU backend, pinned llama.cpp b11306, bundled Qwen3.5-4B Q4_K_M, optimized Swift 6.0.3, 8,192-token context and unchanged 256-token batches. The Linux build supplies a no-op OSLog shim because Apple's logging module is unavailable there; it compiles the production inference and cache logic. Baseline and cached runs execute sequentially. Report medians and observed ranges for repeated cases; five samples do not establish a reliable tail percentile. These results are not iPhone/Metal speed guarantees.

### Observed host results

All 15 paired production-client cases returned identical output text/structured values and generated-token counts. Cache accounting and recovery assertions passed. Across five warm chat follow-ups:

| Metric | Cache disabled | Cache enabled |
| --- | ---: | ---: |
| Median prompt preparation | 10.24 s | 2.77 s |
| Median first published chat update | 10.32 s | 2.85 s |
| Median complete response | 11.70 s | 4.09 s |
| Observed complete-response range | 11.47–12.54 s | 4.02–4.16 s |
| Median generation | 1.30 s | 1.32 s |

The complete-response median fell 65%; generation time did not improve. Individual IDE review and repair completions fell from 10.03 to 5.89 seconds and 13.26 to 5.71 seconds, respectively. The second math plan fell from 20.18 to 5.23 seconds. These are completion-level comparisons, not whole IDE tasks or complete calculator-plus-explanation requests. A changed project and a return to chat after math correctly missed the single-entry cache.

Retained checkpoints ranged from about 58.3 to 82.3 MiB. Streaming cancellation cleared retained state; the next request recovered through full processing. The production memory-warning path returned the same answer while retaining zero checkpoint bytes. Host memory-admission checks are covered with a test backend; the iOS-specific available-memory query still requires device validation.

### Complete guarded-header task

Both runs passed the strict generated-C checks and followed the same four model calls: write, review/read, repair, and final confirmation. Both produced 155 tokens and byte-identical final headers. This task retains the required repair step; caching did not obtain a faster result by skipping validation or returning different code.

| Sum across the four calls | Cache disabled | Cache enabled |
| --- | ---: | ---: |
| Model loading | 1.81 s | 1.93 s |
| Prompt preparation | 39.78 s | 20.95 s |
| Generation | 11.36 s | 10.88 s |
| Total inference | 52.96 s | 33.77 s |

Total inference fell 36% in this paired sample. The harness reported 52 and 33 whole elapsed seconds, respectively (integer-truncated, including its tool/verification work). Use the precise inference sums for that percentage; it is not a five-run whole-task median. Raw traces and matched tool steps/header are in `guarded-agent-{baseline,cached}.txt` and `guarded-agent-summary.json`.

A useful limit for the next iteration is `total ≈ load + prompt + generation + tools`. Caching leaves generation work largely unchanged. Measure the phone's actual phase proportions before predicting an overall gain: if generation dominates on Metal, the next improvement must reduce verified generation cost or necessary output, not simply raise the cache's token cap.

## Regression coverage

The 17-case lightweight suite passed. The unchanged grammar sampler also passed 198 exact decisions, including 98 forced fallbacks. The math regression runs passed 10 Swift domain tests, 10 Python engine tests, and the native bridge cold/warm, cross-thread, deadline, cancellation, isolation/busy, and recovery checks.

The lightweight suite exercises exact matching after generation; changed suffixes; changed file/project prefixes; truncated histories; context replacement; partial restore failure and full fallback; failed capture; allocation-budget rejection; low-headroom eviction and recovery; cache-disabled processing; memory warnings before and during capture; cancellation during capture and prefill; decode failure after capture and subsequent recovery; checkpoint boundary selection; and alternating modes.

The real-model harness compares production API outputs and token counts. The standalone native investigation separately tested next-token score and full-token-sequence equivalence. Matching a small corpus is evidence, not a proof for every Metal device or all conversations. Keep the fallback and preserve the raw measurements when comparing future implementations.

### Existing generation-quality failure found by stricter checks

The generic header task (`--snapshot --header-only --no-prompt-cache`) failed a newly strengthened, independent repeated-inclusion check. After six completions, the uncached model produced a function definition *after* `#endif`. It works when included once but is redefined when the header is included twice. The emitted header and compiler error are preserved in `known-header-guard-{failure,error}.txt`. This is a pre-existing model/orchestration quality limitation demonstrated with caching disabled, not a cache regression. It is not counted as a successful performance sample.

The strict check remains in the harness: two includes, warnings treated as errors, and results for square(0), square(7), and square(-3). A separate `--guarded-header` task explicitly asks for a self-contained header with the entire definition inside its guard, no extra files, and no run. Baseline/cached comparisons use that same explicit task. This does not establish that all generic code requests produce correct headers; broader code-quality improvements need their own failing-case corpus and validation.

## Reproduction

The fast policy/failure suite needs only Swift 6:

```sh
scripts/test-prompt-cache.sh
```

On a Mac with the repository's pinned llama framework and model assets:

```sh
scripts/test-cache-model.sh baseline 5 > baseline.jsonl
scripts/test-cache-model.sh cached 5 > cached.jsonl
python3 scripts/compare-cache-results.py baseline.jsonl cached.jsonl
scripts/test-local-sampler.sh
scripts/test-local-agent.sh --snapshot --header-only --guarded-header --no-prompt-cache
scripts/test-local-agent.sh --snapshot --header-only --guarded-header
scripts/test-math-domain.sh
```

Run inference benchmarks sequentially, with no competing model workloads. The agent harness independently compiles and checks its resulting header. Use the same device, source snapshot, task, power mode, and thermal state for each comparison. For stronger performance estimates, alternate baseline/cached ordering across several repetitions and include separate cold-start runs.

The standalone real-model and agent harnesses also accept `LLAMA_BACKEND_DIR` for Linux dynamic backend discovery; the app uses its bundled framework. Do not confuse harness setup with a product setting.

## Device telemetry and next gates

All three inference modes now record locally under `app.lilc` / `AgentPerformance`:

- Load, prompt rendering/tokenization, total prompt preparation, actual decode, state restore/capture, generation, and total durations.
- Time to first generated token and first published chat update. Chat update timing measures the callback, not completion of UI rendering. For the IDE, first-update timing marks the complete validated envelope becoming available; it is not the first JSON character or a measured UI render. Math planning is internal and has no visible-update timestamp. An unavailable timestamp is logged as `-1`.
- Input, newly decoded, reused, and generated token counts; retained cache bytes; hit/miss and capture status; success, failure, or cancellation. EOS is excluded from generated-token counts.

Only timing/count/status fields are logged; no prompts, source files, or answers are included. Prompt preparation includes restore/capture overhead, so it can be compared directly against full preparation. Generation timing includes sampling, decoding, and response finalization; total time includes model loading when needed.

Before calling this a verified iPhone speedup, run the corpus and representative longer IDE tasks on a physical phone. Measure peak resident memory, first visible output, whole-task duration, output token count, tool calls, successful repairs, and thermal state. Exercise memory warnings, stopping a response, switching files, and longer conversations. The available Linux environment cannot build Xcode targets, validate UIKit notification delivery, or establish Metal output equivalence. Runtime tuning and speculative decoding remain separate experiments; the earlier speculative code-output regression is not enabled here.
