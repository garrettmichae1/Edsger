# Further latency investigation — October 3, 2026

Follow-up: [automatic prompt reuse implementation](PROMPT_REUSE_IMPLEMENTATION.md) records the subsequent integration and regression results.

Status at the time of this investigation: measured prototype and engineering recommendation. App baseline is `e97ae53ea75483466a2c4bc32ab72736487bf8fa`. This investigation adds documentation, synthetic fixtures, measurements, and a standalone probe; it does not enable caching or change runtime settings in the iOS app.

## Decision

Implement bounded, automatic reuse of exact prompt prefixes next, with timing coverage for text chat and the math planner. This is the strongest measured opportunity for reducing the wait before generation. Token generation remains a separate bottleneck, especially on Metal where the previous binary-search run spent about 18.3 of 22 seconds generating output. Do not apply the CPU percentages below to an iPhone.

The existing model is already resident, chat already streams, thinking output is disabled, the IDE already batches tools and asks for short progress messages, and grammar sampling was optimized in the previous change. Another background queue or a lower maximum output limit does not remove the demonstrated inference cost. Cutting a token limit saves nothing when a response already ends before it, and can truncate valid code otherwise.

## Exact-prefix checkpoint experiment

The app clears inference memory and reprocesses the whole prompt on every IDE, text, and math-planner call. Generated IDE JSON is reserialized before the next call, so its generated token sequence cannot simply be kept and appended to. Qwen3.5 also maintains recurrent state as well as attention memory.

The probe instead captures the native **full sequence state before generation**, at a batch-aligned prompt prefix. It restores that immutable checkpoint only when the next prompt has exactly the same token prefix, then decodes the remaining prompt normally. It uses the pinned runtime's `llama_state_seq_get_size`, `llama_state_seq_get_data`, and `llama_state_seq_set_data`. It does not use partial recurrent rollback or assume attention memory alone is sufficient.

Environment: Linux x86-64, AMD EPYC 9V74 host, CPU backend, four inference threads, 8,192-token context, 256-token batch and microbatch. Model: unchanged Qwen3.5-4B Q4_K_M, SHA-256 `25082a7dd3776cc3c741c6347d3bd04523f05796607b3fbc32fa3a25dfa1418c`. Runtime: llama.cpp b11306. Model loading is excluded. These are one paired run per case, not medians, percentiles, device measurements, or complete IDE-task benchmarks.

| Completion | Prompt tokens | Reused tokens | Full prompt processing | Restore + remaining prompt | Reduction | Checkpoint memory |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| IDE review after first write | 544 | 256 | 8.49 s | 4.50 s | 47.0% | 58.3 MiB |
| IDE repair after file read | 600 | 512 | 9.63 s | 1.49 s | 84.5% | 66.3 MiB |
| Text-chat follow-up | 685 | 512 | 11.03 s | 2.82 s | 74.4% | 66.3 MiB |
| Math-planner request | 1,162 | 1,024 | 17.43 s | 2.30 s | 86.8% | 82.3 MiB |

All four pairs produced exactly identical complete token sequences, including EOS. The maximum absolute difference in next-token scores after prompt processing was zero in every pair. IDE and math runs used their production grammars and candidate-first greedy sampling; chat used unconstrained greedy sampling. The saved checkpoint survived subsequent source-prompt processing and eight generated tokens before restoration. A changed first token failed the exact-prefix comparison.

Saving a checkpoint cost 22–32 ms; restoring one cost 5–7 ms on this CPU host. Save cost is paid while capturing a reusable prefix, and is not included in the cached-hit column. Approximate prompt-plus-generation duration fell from 10.37 to 6.32 seconds for the first IDE case, 13.97 to 5.53 for repair, 12.38 to 4.12 for chat, and 20.11 to 4.91 for the math plan. These are individual completions and exclude model loading, tools, calculator execution, UI work, and checkpoint capture. Generation speed itself was essentially unchanged; the work saved was prompt processing.

The fixtures are synthetic snapshots exported through the production prompt builders. The IDE snapshots deliberately model the declaration-only header and subsequent review/repair flow seen previously. The chat follow-up asks for a one-sentence explanation of `return`; the two math requests share planner instructions but ask different calculations. Output equivalence checks cache correctness, not comprehensive answer quality. This is not a full app replay.

## Runtime settings

Pinned `llama-bench`, two measured repetitions after warmup per setting, sequential runs with no concurrent inference. Prompt tests process 512 synthetic tokens; generation tests produce 64 tokens with no supplied prompt. Their benchmark-sized contexts and synthetic inputs differ from the app's 8,192-token context.

| Threads | Batch / microbatch | Prompt tokens/s | Generation tokens/s |
| --- | --- | ---: | ---: |
| 4 | 256 / 256 | 67.49 | 14.44 |
| 8 | 256 / 256 | 119.84 | 17.10 |
| 4 | 512 / 512 | 69.47 | 14.49 |
| 8 | 512 / 512 | 115.92 | 19.96 |

The host exposes nine logical CPUs with an eight-CPU quota. Eight threads improved throughput here, but doubling the batch size produced no consistent prompt-processing gain. The generation differences between the two eight-thread runs require a controlled repeat before attributing them to batch size; single-token generation should not be assumed to benefit directly from a larger prompt batch. These small samples are insufficient to choose an iPhone configuration. The app uses Metal on devices, so CPU thread counts are not a proxy for GPU throughput.

Commands used, substituting the installed binary/model paths:

```sh
llama-bench -m "$MODEL" -p 512 -n 64 -b 256 -ub 256 -t 4,8 -r 2 -ngl 0 -o json
llama-bench -m "$MODEL" -p 512 -n 64 -b 512 -ub 512 -t 4,8 -r 2 -ngl 0 -o json
```

## Speculative generation probe

A second experiment used the pinned `llama-server` with one slot, the same 8,192 context / 256 batch / four CPU threads, zero GPU layers, greedy sampling, and prompt caching disabled. It compared `--spec-type none` against `--spec-type ngram-simple --spec-ngram-simple-size-n 4 --spec-ngram-simple-size-m 8 --spec-draft-n-max 8`. Both used the exact same raw prompts; the code case also used the production grammar. Each server was loaded before timing requests. One pair per task is exploratory, not a latency distribution.

| Case | Baseline generation | Speculative generation | Output check |
| --- | ---: | ---: | --- |
| Code repair | 4.18 s / 60 tokens | 2.94 s / 26 tokens | Failed: different action and output length |
| Text follow-up | 1.15 s / 19 tokens | 1.30 s / 19 tokens | Identical text and tokens, slightly slower |

The speculative code response asked to read `math.h` again, while the baseline emitted a `replace_text` call to repair its declaration. Only 10 of 40 draft tokens were accepted. The shorter speculative request must **not** be counted as a successful speedup: it generated less output and did different work. The text pair preserved its answer but showed no gain. This probe establishes a failed equivalence gate, not the root cause; numerical differences, recurrent rollback, and grammar handling would need isolation before diagnosing an upstream bug. It also does not rule out other draft strategies or larger repetition-heavy tasks.

Recommendation: do not make speculative decoding the default in this runtime yet. Keep this as a separate generation research track after prompt reuse. There is no demonstrated safe generation-rate win for both code and text in this probe. Smaller-model routing also remains unmeasured; it must pass implementation/repair and answer-quality tests before replacing the current model automatically.

`spec-results.json` retains timings, complete synthetic outputs, output token IDs, and stop reasons. `scripts/speculative-latency-bench.py` reproduces the local server comparison with paths supplied as arguments. It starts servers sequentially on loopback, shuts them down after each mode, and makes no external requests. Run it separately from other benchmarks to avoid CPU contention:

```sh
python3 scripts/speculative-latency-bench.py \
  "$LLAMA_LIB" "$MODEL" Docs/benchmarks/prompt-reuse-2026-10-03 "$PROBE_OUTPUT"
```

## Automatic behavior to implement

1. **Shared prompt-processing implementation.** Route IDE completion, text chat, and math planning through one helper. Record loading, tokenization, restore, prompt decoding, first visible output, generation, token counts, cache-hit/miss reason, and checkpoint bytes. Text and math currently lack the IDE's detailed timing coverage. Keep telemetry local and exclude source/conversation contents.
2. **Bounded native checkpoints.** Select a stable prefix from actual token/message boundaries; keep production batch alignment. Restore only after an exact token comparison and a matching model/context configuration. Always decode a nonempty suffix to obtain fresh logits. On a cache miss or restore failure, clear memory and perform the existing full decode. Publish a checkpoint only after its capture completes successfully.
3. **Memory-aware retention.** Start with one checkpoint and measure its useful hit rate, then consider a small pool under a device-tested byte budget. A provisional 128 MiB budget is an experiment, not a verified phone allowance. Clear on memory pressure and model reset; retain no checkpoint on disk. Three states like those measured would use over 200 MiB. Alternating math planning and explanation can thrash a single-entry cache, so the planner result above is not a guaranteed hit in the complete math-chat pipeline.
4. **Stable instructions before dynamic context.** The IDE currently inserts project state near the beginning of its system prompt. Putting reusable instructions first could preserve more cache hits between requests when file lists or selection change. Treat this as a separate prompt change requiring quality regression tests. Exact-prefix matching must always include the actual current request and context; it must never reuse stale file contents as new input.
5. **Device-tested runtime profiles.** Choose conservative settings by device/model/runtime version, and collect rolling warm timings during real requests. Consider a bounded calibration only when useful; do not delay every request with a benchmark. Track thermal and memory pressure, and revalidate a profile after runtime/model changes. Performance evidence must include task completion and repair rate, not just tokens per second.

## Gates before app integration

The probe is deliberately small: its checkpoint boundary leaves eight tokens before the completion marker and rounds down to 256-token boundaries, capped at 1,536 tokens. That fixture-specific rule is not a production cache policy. It checks basic mismatch rejection, but does not implement automatic miss fallback, eviction, or cancellation handling.

Before enabling the cache, test interruption during prompt processing and generation, switching projects/files, changed or truncated histories, malformed/failed state restoration, model reload, memory-pressure eviction, and alternating IDE/chat/math requests. Re-run generated-code compilation and the existing agent/calculator regression tests. Verify output equivalence on Metal, including long conversations and non-ASCII input. Measure peak resident memory during capture as well as steady-state checkpoint size; copying a state can temporarily require more memory than retaining it.

On a physical iPhone, compare at least five warm runs and a separate cold run for identical chat and code tasks. Record first-token time, full completion time, output tokens, model calls, retries, memory, and thermal state. Keep the automatic full-decode fallback until the cache passes these gates. No Xcode or physical-iPhone validation was available in this investigation.

## Reproducing the checkpoint probe

Fixtures, exact answers, raw JSONL cache measurements, and raw runtime throughput results are in `Docs/benchmarks/prompt-reuse-2026-10-03/`. The C++ source is `scripts/prompt-cache-bench.cpp`. It is a standalone experiment, not an app dependency. Use headers and libraries from the pinned b11306 build and the verified model above.

Example Linux invocation from the repository root (set `LLAMA_SOURCE`, `LLAMA_LIB`, and `MODEL` to local paths):

```sh
c++ -std=c++17 -O2 -Wall -Wextra -Werror \
  -I"$LLAMA_SOURCE/include" -I"$LLAMA_SOURCE/ggml/include" \
  scripts/prompt-cache-bench.cpp -L"$LLAMA_LIB" \
  -lllama -lggml -lggml-base -o /tmp/edsger-cache-bench
PROBE_OUTPUT=$(mktemp -d)
LD_LIBRARY_PATH="$LLAMA_LIB" /tmp/edsger-cache-bench \
  "$MODEL" "$LLAMA_LIB" Docs/benchmarks/prompt-reuse-2026-10-03 "$PROBE_OUTPUT"
```

It prints one JSON measurement per pair, writes decoded answers into the output directory, and fails if either completion fails to end or token sequences differ. Original measurements used the same inference code with local paths embedded; the checked-in version takes paths as arguments and was compiled with warnings treated as errors.
