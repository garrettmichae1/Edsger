# Edsger mini

Chat now offers **Edsger** (the existing bundled Qwen3.5 4B) and **Edsger mini**
(Liquid AI LFM2.5-1.2B-Instruct, Q4_K_M). Existing installs keep Edsger selected.
Mini is experimental and optional; its weights are not added to the app bundle.

## Using and removing Mini

Tap the model name at the top of Chat, or open Settings → Chat → Model.
Download Mini (731 MB), then select it. The download does not change the selection.
Afterward both models work offline. Downloading contacts Hugging Face and its
delivery network; prompts, conversations, and project contents are never sent.

Choose Edsger at any time between replies. **Delete download** releases Mini's
context/weights, selects Edsger, and deletes only Mini's optional model file.
Conversations, drafts, pins, project files, and restore points are untouched.
If deletion fails, Edsger remains selected and an error is shown; deletion can be
retried. Selection is global for Chat, not stored as a migration in conversation
files. The feature can also be removed by reverting its single integration commit;
old app versions ignore the new preference and optional model directory.

## What uses which model

| Work | Model / engine |
| --- | --- |
| Ordinary Chat | Selected model |
| Explicit basic arithmetic | Existing deterministic calculator shortcut |
| Interpreting other calculation requests | Existing Qwen3.5 4B planner, regardless of Chat selection |
| Actual calculations | Existing bounded SymPy engine |
| Explanation after a calculation | Selected Chat model |
| IDE agent | Existing Qwen3.5 4B |
| Markdown, code, and LaTeX display | Existing app renderers |

Early live host tests of Mini as the planner produced invalid bounds for RREF and
tried to evaluate an unsupported limit. The app's validation rejected these
requests, but they are a regression in usability. Consequently Mini does **not**
plan calculations in this release. This is intentional, not a silent retry loop.
Model explanations remain AI-generated and are not verified by the calculator.
Formatting support does not establish mathematical correctness.

Complex calculations and entering/leaving the IDE can require model switches and
be slower than ordinary Mini chat. No iPhone speed multiplier is promised.

## Artifact and license

- Repository: `LiquidAI/LFM2.5-1.2B-Instruct-GGUF` on Hugging Face.
- Revision: `8ed288026e23958ad9dfa92d53ed773a8eee7125`.
- File: `LFM2.5-1.2B-Instruct-Q4_K_M.gguf`.
- Exact bytes: `730895168`.
- SHA-256: `b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5`.
- Download: https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/8ed288026e23958ad9dfa92d53ed773a8eee7125/LFM2.5-1.2B-Instruct-Q4_K_M.gguf
- License: LFM Open License v1.0, included with normalized line endings in `Resources/LiquidAI-LICENSE.txt`
  and exposed in Settings → Open-source licenses. This is an open-weight model
  with its own license, not Apache-licensed app code. Its commercial grant has a
  $10 million annual revenue threshold; review the full license for distribution.

No framework upgrade or new package dependency is needed: llama.cpp b11306 already
supports the `lfm2` architecture. Mini uses its native start-of-text token exactly
once, ChatML turns, no Qwen thinking prefix, and Liquid's temperature 0.1 / top-k
50 / repetition penalty 1.05 profile. Standard's prompt and sampler are unchanged.

## Runtime and installation safety

- One `LocalAgentClient` actor owns at most one native model/context. Before loading
  another it frees the prior context, model, and prompt snapshots. Agent and math
  always explicitly request Standard; Chat never changes the IDE's model policy.
- `SelectedChatClient` pins the selection and holds a reply lease through planning,
  calculation, and explanation. Switching/deleting is blocked until the reply has
  actually exited, including after Stop. Draft editing and history are independent.
- Download uses URLSession's disk download API, not a 731 MB in-memory `Data`.
  Progress and cancellation are available. Byte count, GGUF magic, and streaming
  SHA-256 must match before the completed temporary file is installed.
- Verification runs off the main actor in 1 MiB chunks. Existing downloads are
  reverified on first use after launch; incomplete/invalid files never reach llama.
- Optional files live in `Application Support/lilC/OptionalModels`, excluded from
  backups. Download checks for approximately 1.5 GB free storage. The original
  bundled model is never overwritten or removed.
- A missing download after restore falls back to Standard. A failed Mini selection
  also restores Standard as the preference. Background suspension can pause a
  download; termination requires restarting it. There is no background resume
  service or automatic download.
- OSLog performance records include model identity, phase timings and token counts,
  never prompt contents. Downloading an inactive model adds disk usage, not another
  resident model's RAM. Verification/download buffers still have transient costs.

## Verification

Portable state tests: `bash scripts/test-model-selection.sh`.
Existing chat regressions: `bash scripts/test-chat-experience.sh`.
Math engine regressions: `python scripts/test-math-engine.py` (SymPy environment).
Project reference check: `python scripts/check-editor-project.py`.

For a real-model macOS smoke test, fetch the normal assets, download the exact Mini
artifact above to a local path, then run:

```sh
bash scripts/test-mini-model.sh /path/to/LFM2.5-1.2B-Instruct-Q4_K_M.gguf
bash scripts/check-local-inference-build.sh
```

The smoke uses production inference and checks Mini text/display math, Standard
planning under a Mini selection, model transitions, cancellation, and release.
State tests cover install/cancel, persistence, corrupted/missing weights, failed
loads/deletions, reply leases, and prompt control-token escaping.

This implementation was checked on a Linux host with Swift 6 strict concurrency,
llama.cpp b11306, and the exact pinned Mini and bundled Standard artifacts. The
live smoke passed Mini physics/display-math responses, exact Standard planning for
percentage/integration/RREF, ambiguous variance, unsupported limits, a follow-up,
return to Mini, streaming cancellation, and resource release. Model state and
existing chat regression harnesses passed; all 10 Python math tests passed.
Apple-only imports used compile-only host stand-ins where necessary, so these
checks are not an Apple SDK build. The downloaded file's hash was independently
verified with Python SHA-256. Host timings are not iPhone benchmarks.

Native iOS build, CryptoKit/URLSession installation, and visual/device performance
remain Xcode/device checks. Linux can check Swift concurrency and native llama
inference but does not validate SwiftUI types or Apple's SDK implementations.

On a physical iPhone: download/cancel/retry; select Mini; send a normal question;
compute `1/3 + 1/6`; integrate `x^2` from 0 to 1; open the IDE; return to Mini;
stop a streaming response; switch/delete Mini; confirm histories and projects
remain; relaunch with Mini selected and after deletion. Exercise low storage,
offline download failure, light/dark appearances, Dynamic Type, and VoiceOver.
Compare cold and warm first-token time, complete-answer time, peak app memory,
and sustained 20-turn heat/battery behavior on the same device.
