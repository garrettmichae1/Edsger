# Bundled Chat models

Chat offers exactly two choices: **Edsger 1.0** (Qwen3.5 4B Q4_K_M) and
**Edsger Mini 1.0** (Liquid AI LFM2.5-1.2B-Instruct Q4_K_M). Tap the name/chevron
at the top of Chat for a compact native menu. Settings uses the same menu.
Neither picker contains descriptions, download controls, or technical details.
The existing saved choice is preserved; new installs still default to Edsger 1.0.

## Build setup

Both model files are copied into the built app by Xcode's Resources phase.
A fresh checkout requires `bash scripts/fetch-agent-assets.sh`, which now also
fetches Mini. When updating an existing checkout with the original assets, run:

```sh
bash scripts/fetch-mini-assets.sh
```

The large GGUF binaries remain excluded from Git. Pulling supplies the resource
references and setup script; running the script supplies the actual Mini weights
before building. It downloads an immutable revision to a temporary file, checks
SHA-256 before publishing it, and verifies existing files on subsequent runs.
Bundling Mini adds 730,895,168 bytes (about 731 MB) of model storage to the app.
Both choices work offline immediately after installation; there is no in-app
model download or deletion screen. Required model notices remain in Settings →
Open-source licenses.

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

## Runtime and upgrade safety

- One `LocalAgentClient` actor owns at most one native model/context. Before loading
  another it frees the prior context, model, and prompt snapshots. Adding a bundled
  asset does not keep a second model resident in RAM.
- `SelectedChatClient` holds a reply lease through planning, calculation, and
  explanation. Switching is blocked until the reply has exited, including Stop.
  Conversations, drafts, pins, project files, and restore points are preserved.
- Mini is resolved from the app bundle. Its byte count, GGUF magic, and streaming
  SHA-256 are verified off the UI actor on first use after launch, using 1 MiB
  chunks. Missing or invalid assets fall back to Standard and show an error.
- After successful verification, the exact legacy Mini file in
  `Application Support/lilC/OptionalModels` is removed to reclaim duplicate storage.
  Bundle resources and the surrounding directory are never deleted. Cleanup
  failure does not prevent using the verified bundled model.
- OSLog records include model identity, phase timings and token counts, never
  prompt contents. Model loading and verification still have transient costs.

## Verification

```sh
bash scripts/test-model-selection.sh
python3 scripts/check-editor-project.py
bash scripts/fetch-mini-assets.sh
bash scripts/test-chat-experience.sh
```

State tests cover exact names, bundle lookup, defaults, selection persistence,
reply leases, missing/corrupt assets, load failure recovery, and native templates.
The project check ensures both model resources are linked exactly once and that
Mini's fetch revision/filename/hash agree with runtime metadata. The asset script
verifies the real artifact. Swift 6 strict-concurrency host type checks and SwiftUI
syntax parsing supplement these checks; Apple-only modules use compile-only host
stand-ins, so those checks do not establish an Apple SDK build or CryptoKit runtime
verification.

Earlier live Linux smoke tests with llama.cpp b11306 and both exact artifacts passed
Mini text/display-math, Standard percentage/integration/RREF planning, ambiguous
variance, unsupported limits, follow-up planning, model transitions, cancellation,
and resource release. This packaging change leaves their inference paths intact.
For a real-model macOS check after fetching assets:

```sh
bash scripts/test-mini-model.sh lilC/Resources/Models/LFM2.5-1.2B-Instruct-Q4_K_M.gguf
bash scripts/check-local-inference-build.sh
```

For this packaging change, bundle/selection tests, project references, the real
asset hash, strict-concurrency type checks and UI syntax checks passed on Linux.
The unchanged chat regression harness compiled but hit a host Foundation crash
while accessing `/proc`; it needs a macOS rerun. A native iOS build and visual
checks require Xcode and a device.

On iPhone, test the two-option menu in light/dark mode, Dynamic Type and VoiceOver;
select Mini, send a normal question, compute `1/3 + 1/6`, integrate `x^2` from 0 to 1,
open the IDE, return to Mini, stop a response, switch models and relaunch. Confirm
both choices work in airplane mode and histories/projects remain. An upgrade with
Mini already selected should preserve the choice and reclaim its old duplicate
on first verified use. Compare cold/warm first-token time, answer time, peak app
memory and sustained heat/battery behavior on the same device.
