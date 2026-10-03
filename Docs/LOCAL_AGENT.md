# Bundled local agent

The iPhone app includes Qwen3.5-4B Q4_K_M (text only) and llama.cpp. Inference stays on the iPhone. The Xcode project targets iOS 18 or later.

Before opening the Xcode project on a new checkout, run `scripts/fetch-agent-assets.sh`. It downloads both pinned models and the iOS device XCFramework, verifies SHA-256 hashes, and puts them where the project references them. The large binaries are excluded from Git; they are copied into the built app by Xcode.

For simulator builds, install CMake 3.28 or later and run `scripts/build-llama-simulator.sh` once. The official release archive contains the device slice but not a simulator slice.

Model: [Qwen/Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B), Apache 2.0. GGUF conversion: [Canfield/Qwen3.5-4B-Q4_K_M-GGUF](https://huggingface.co/Canfield/Qwen3.5-4B-Q4_K_M-GGUF). Runtime: [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp), MIT.

The bundled model is about 2.7 GB. The simulator uses CPU inference because its mixed CPU/Metal path corrupted model output in testing. An offline reply passed in the iPhone simulator, but the first response took about two minutes. On-device memory, speed, and Metal output still need testing on a physical iPhone, especially older iOS 18 devices.

## Agent reliability and regression checks

The local runtime constrains every generated token with a llama.cpp grammar for the supported tool schemas. This replaces the fragile open JSON-string prefill: C quotes, backslashes, and newlines must now be valid JSON before any file operation is dispatched. Truncated generations never execute partial calls. Responses have a 3,072-token budget and batches contain at most four calls.

Project context and operating instructions share one system message. Assistant tool calls are preserved in the model transcript, and results use Qwen's `tool_response` turn format. System/project instructions are retained while older complete user turns are removed to fit the actual token budget. Recent history is scoped to its project; legacy unscoped history is not supplied to new agent runs. File text cannot inject chat-template delimiters.

`replace_text` changes one exact unique substring, avoiding regeneration of entire files for small edits. Existing file mutations require a current content snapshot; an uninspected or changed file returns its contents for reassessment before a retry. Writes and deletes report disk failures instead of claiming success. Program runs return output after a bounded wait, including a distinct still-running state. Stop, a new conversation, or switching files during inference prevents late actions from being applied. Repeated calls and total steps are bounded. After successful mutations, one bounded completion review can repair missing implementation before the final answer is shown; this intentionally adds a small amount of latency to prevent premature completion.

Run the app regression suite with Xcode's lilCTests target. It includes a scripted full session through read/edit/create/run/delete, disk verification, rejected paths, uninspected writes, cancellation, prompt preservation, and write failures. These tests do not load the model or spend provider tokens.

Run `scripts/test-local-agent.sh` on macOS for an opt-in real-model test. It uses the downloaded macOS llama framework (retained in `llama-device-only.xcframework` after the simulator setup), loads the bundled model, and verifies edit/create/delete requests in an isolated temporary directory. It also compiles and executes the generated square function with host Clang; app tests separately exercise PicoC. No network inference is used. On the development Mac, the three small requests completed in approximately 10, 12, and 5 seconds including the completion review (the first request also includes model loading); these are smoke measurements, not iPhone performance claims or a before/after benchmark. Larger changes and simulator CPU inference take longer. Physical-device Metal output, peak memory, and latency still require an iPhone pass.


## Performance investigation

See [Agent performance](AGENT_PERFORMANCE.md) for the measured bottlenecks, first optimizations, retained correctness checks, and the path toward 20–30-second requests. Small selected files are now supplied as current snapshots, and the agent's successful edits refresh its inspection state. Physical iPhone latency remains to be measured. Run `scripts/test-local-agent.sh --snapshot --binary-search` for the expanded real-model check and per-stage timing output.

## Bundled Chat models

Chat selects **Edsger 1.0** or **Edsger Mini 1.0** from a compact two-option menu.
Both GGUF files are bundled by Xcode after asset setup; existing checkouts can run
`bash scripts/fetch-mini-assets.sh` to add Mini. The shared actor releases each
model before loading another; the agent and math planner still explicitly request
Qwen. See [Chat models](EDSGER_MINI.md) for provenance, packaging, upgrade safety,
lifecycle tests, and device validation.
