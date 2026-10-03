# EDSGER offline teaching chat

EDSGER opens directly to chat. It works offline with the bundled Edsger 1.0 and
Edsger Mini 1.0 choices. The IDE button opens the existing project home screen.
Courses is no longer part of the chat navigation. No purchase, account or cloud
service is required for the current chat or document feature; Pro gating is deferred.
See [local document chat](DOCUMENT_CHAT.md) for supported formats, limits and tests.

## Separation from the coding agent

`TutorSession` owns tutoring conversations and never receives a workspace or file tool dispatcher. Its default client now routes supported calculations through the bounded on-device SymPy engine; see [Math engine](MATH_ENGINE.md). `TutorPrompt` asks EDSGER to teach C, Python, JavaScript, Lua, and general academic topics, to acknowledge uncertainty, and not to claim browsing, execution, or file edits. Examples appear in chat as fenced code blocks. This is general tutoring, not a promise of factual accuracy or access to current information.

`LocalAgentClient.reply` produces plain text with streamed updates rather than the agent's JSON/tool grammar. Both paths use the same actor-owned model and context: there is no second model allocation, and inference cannot overlap on the shared handles. The tutor has a 2,048-token response limit; complete older turns are dropped from inference context when needed, while the saved conversation remains on device. Stop checks between prompt batches and generated tokens. Model loading is synchronous inside the background actor and cannot be interrupted partway through loading.

Opening Learn stops an active coding-agent turn. Leaving EDSGER stops generation and preserves the partial answer. Cancelled or old responses cannot update a newly selected conversation. Document chat receives only the passages from the selected imported file; workspace files are not automatically sent to the tutor.

## Interface and history

The interface uses floating circular actions, a spacious transcript and a rounded
Ask EDSGER composer. The plus button offers Files and academic topic starters; the
magnifier searches saved chats, and the blue button sends or stops a response.
Light and dark appearance follow the app setting. IDE remains available in the
footer and history sheet. Info explains the offline chat and agent modes.

History is local at Application Support/lilC/edsger-conversations.json, separate
from coding-agent histories and source files. It supports search, pinning, selection
and deletion. Drafts and attachments survive switching/relaunch. Up to 100 ordinary
conversations are retained; pinned, active and unfinished chats are protected.
See [chat experience](CHAT_EXPERIENCE.md). Imported files have their own bounded
Recent library; deleting a conversation does not delete shared imported files.
App backups follow ordinary iOS behavior. There is no network inference.

## Math notation

Chat renders math offline with SwiftMath 1.7.3, pinned by Swift Package Manager (including its bundled fonts). `MathMessage` separates prose, inline math, display math, and code; `MathAnswerView` renders answers and `MathEquationView` is reusable for future scan previews. Stored messages and the existing copy-answer action retain the original LaTeX text.

The tutor prompt requests `\(...\)` inline and `\[...\]` for display math, with standard LaTeX commands for algebra, calculus, matrices, and statistics. The parser also accepts `$...$` and `$$...$$`, protects fenced/inline code and ordinary dollar amounts, and leaves unclosed streamed expressions as text. Unsupported expressions fall back to their source rather than disappearing. Typesetting itself does not verify mathematics or recognize handwriting. Separately, supported chat calculations use the [on-device math engine](MATH_ENGINE.md), with interpreted input and exact result displayed before the AI explanation.

Display equations scroll horizontally rather than shrinking below a readable size. Long-press an equation to copy its LaTeX. Math follows appearance and Dynamic Type; accessibility exposes equation source, not a full semantic spoken-math translation. Rendering uses a bounded image cache keyed by expression, font size, mode, and appearance; completed formulas are reused during streaming. Input length, brace depth, and output dimensions are bounded. Fonts render at device scale without a web view or network request.

Tests cover streaming, delimiters, currency, code isolation, invalid notation, representative subject formulas, cache reuse, font scaling, and offscreen light/dark chat rendering. `scripts/test-local-tutor.sh --math` checks actual bundled-model output for algebra, calculus, linear algebra, and statistics on the Mac; it does not establish iPhone latency. The renderer itself is exercised by iOS simulator unit tests.

## Rich chat formatting

Textual 0.5.0 is pinned for structured prose, headings, nested lists, tables, blockquotes, text selection, and locally bundled Prism syntax highlighting. The response formatter still uses `MathMessage` to protect code and incomplete equations. `ChatMarkdownParser` attaches existing SwiftMath images to Textual's Markdown structure, including equations inside table cells and lists. Textual's own math syntax extension is deliberately disabled; `MathTypesetter` and display equation cards are unchanged.

The app does not fetch images referenced in generated Markdown: image URLs become alt text before Textual resolves attachments. Links are ordinary user-activated links. Unsupported math retains its source, code remains literal, and stored conversations and the copy-answer action retain their original content. The model prompt, inference, history, and navigation are unchanged by this integration.

Tests exercise mixed Markdown/math, table and list structure, code isolation, remote-image suppression, streaming prefixes, and offscreen light/dark rendering. Textual and runtime dependency notices are bundled in `Textual-LICENSES.txt`.

## Validation

Unit coverage checks prompt separation/template escaping, streaming completion, local save/reload, independent conversations, deletion, stale updates after cancellation, and failure/retry behavior. UI checks cover Chat / Courses navigation, course-to-editor return, the keyboard layout, and a real response from the bundled model. Physical-iPhone memory/latency and longer educational answers should still be exercised before publishing.

The implementation passed the app unit suite and both EDSGER UI checks, including an actual bundled-model reply in the simulator. A Release build for iOS also succeeded. `scripts/test-local-tutor.sh` exercises the actual bundled model on macOS with physics, history, and four-language questions; these are basic wiring/content smoke checks, not a comprehensive assessment of teaching accuracy. Simulator and Mac timings do not establish iPhone performance.


## Document feature validation (2026-10-03)

The validation above describes earlier rendering work. For the new document feature,
portable parser/routing/session regressions and real-model prompt smoke checks passed
on the host. Native PDF/UI tests were added but not run here; Xcode and device
validation remain required. Details are in [DOCUMENT_CHAT.md](DOCUMENT_CHAT.md).
