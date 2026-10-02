# EDSGER offline teaching chat

EDSGER's Chat / Courses interface opens when the app launches. Chat is free, text-only, and works offline with the already-bundled Qwen3.5-4B model. The IDE button with the home icon opens the existing project home screen. Courses retains the existing lessons, quizzes, and Linux-course ownership flow. Existing course purchases are unchanged; no purchase, agent toggle, account, or cloud service is required for Chat.

## Separation from the coding agent

`TutorSession` owns tutoring conversations and never receives a workspace or file tool dispatcher. `TutorPrompt` asks EDSGER to teach C, Python, JavaScript, Lua, and general academic topics, to acknowledge uncertainty, and not to claim browsing, execution, or file edits. Examples appear in chat as fenced code blocks. This is general tutoring, not a promise of factual accuracy or access to current information.

`LocalAgentClient.reply` produces plain text with streamed updates rather than the agent's JSON/tool grammar. Both paths use the same actor-owned model and context: there is no second model allocation, and inference cannot overlap on the shared handles. The tutor has a 2,048-token response limit; complete older turns are dropped from inference context when needed, while the saved conversation remains on device. Stop checks between prompt batches and generated tokens. Model loading is synchronous inside the background actor and cannot be interrupted partway through loading.

Opening Learn stops an active coding-agent turn. Leaving EDSGER stops generation and preserves the partial answer. Cancelled or old responses cannot update a newly selected conversation. Courses is a separate tab, leaving room for explicit lesson context and guided course conversations later; this version does not automatically send course or workspace files to the tutor.

## Interface and history

The screenshot-inspired interface uses floating circular actions, a Chat / Courses capsule, a spacious transcript, and a rounded Ask EDSGER composer. The plus button offers academic topic starters, the magnifier searches saved chats, and the blue button sends or stops the response. There are no inactive microphone/voice buttons. Light and dark appearance follow the app setting. IDE remains available in the footer and history sheet; files are accessed through the IDE. The footer Info button opens a matching offline explainer with Chat / Agent tabs, a three-step interactive example for each mode, and expandable offline-use details. Opening Info does not stop generation or change the conversation.

History is local at Application Support/lilC/edsger-conversations.json, separate from coding-agent histories and source files. Conversations are automatically titled from their first question. The history sheet supports search, selection, new chats, and swipe-to-delete. Up to 100 conversations are retained. Deleting a chat removes its local saved content; app backups follow ordinary iOS behavior. There is no network inference or additional model download.

## Math notation

Chat renders math offline with SwiftMath 1.7.3, pinned by Swift Package Manager (including its bundled fonts). `MathMessage` separates prose, inline math, display math, and code; `MathAnswerView` renders answers and `MathEquationView` is reusable for future scan previews. Stored messages and the existing copy-answer action retain the original LaTeX text.

The tutor prompt requests `\(...\)` inline and `\[...\]` for display math, with standard LaTeX commands for algebra, calculus, matrices, and statistics. The parser also accepts `$...$` and `$$...$$`, protects fenced/inline code and ordinary dollar amounts, and leaves unclosed streamed expressions as text. Unsupported expressions fall back to their source rather than disappearing. This is typesetting, not mathematical verification or handwriting recognition.

Display equations scroll horizontally rather than shrinking below a readable size. Long-press an equation to copy its LaTeX. Math follows appearance and Dynamic Type; accessibility exposes equation source, not a full semantic spoken-math translation. Rendering uses a bounded image cache keyed by expression, font size, mode, and appearance; completed formulas are reused during streaming. Input length, brace depth, and output dimensions are bounded. Fonts render at device scale without a web view or network request.

Tests cover streaming, delimiters, currency, code isolation, invalid notation, representative subject formulas, cache reuse, font scaling, and offscreen light/dark chat rendering. `scripts/test-local-tutor.sh --math` checks actual bundled-model output for algebra, calculus, linear algebra, and statistics on the Mac; it does not establish iPhone latency. The renderer itself is exercised by iOS simulator unit tests.

## Rich chat formatting

Textual 0.5.0 is pinned for structured prose, headings, nested lists, tables, blockquotes, text selection, and locally bundled Prism syntax highlighting. The response formatter still uses `MathMessage` to protect code and incomplete equations. `ChatMarkdownParser` attaches existing SwiftMath images to Textual's Markdown structure, including equations inside table cells and lists. Textual's own math syntax extension is deliberately disabled; `MathTypesetter` and display equation cards are unchanged.

The app does not fetch images referenced in generated Markdown: image URLs become alt text before Textual resolves attachments. Links are ordinary user-activated links. Unsupported math retains its source, code remains literal, and stored conversations and the copy-answer action retain their original content. The model prompt, inference, history, and navigation are unchanged by this integration.

Tests exercise mixed Markdown/math, table and list structure, code isolation, remote-image suppression, streaming prefixes, and offscreen light/dark rendering. Textual and runtime dependency notices are bundled in `Textual-LICENSES.txt`.

## Validation

Unit coverage checks prompt separation/template escaping, streaming completion, local save/reload, independent conversations, deletion, stale updates after cancellation, and failure/retry behavior. UI checks cover Chat / Courses navigation, course-to-editor return, the keyboard layout, and a real response from the bundled model. Physical-iPhone memory/latency and longer educational answers should still be exercised before publishing.

The implementation passed the app unit suite and both EDSGER UI checks, including an actual bundled-model reply in the simulator. A Release build for iOS also succeeded. `scripts/test-local-tutor.sh` exercises the actual bundled model on macOS with physics, history, and four-language questions; these are basic wiring/content smoke checks, not a comprehensive assessment of teaching accuracy. Simulator and Mac timings do not establish iPhone performance.
