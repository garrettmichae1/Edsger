# Drafts, scrolling, and generation status

Implemented 2026-10-03 UTC for the iPhone app.

## Draft preservation

EDSGER keeps an independent unfinished message for each conversation and restores
the selected conversation when reopening the app. New Chat reuses only a chat
that has neither messages nor a draft. Sending clears the current draft; other
drafts remain intact. History shows a Draft badge, uses draft text to identify
otherwise empty chats, and searches unfinished text too.

Drafts and the selected conversation ID are stored in a small adjacent
`edsger-conversations.drafts.json` file. Existing conversation JSON stays
compatible. Typing debounces writes by 350 ms and does not rewrite full history.
Chat transitions, sending, leaving the screen, and an inactive/background scene
flush pending changes immediately. Writes are atomic and use the same file
protection as chat history. Abrupt termination before the debounce/lifecycle
flush can lose the most recent keystrokes; this is not crash-proof journaling.

Deleting a conversation deletes its draft. History pruning retains pinned chats,
the active chat, and every chat with an unfinished draft, then fills the normal
100-chat budget with recent completed chats. More than 100 protected chats can
temporarily exceed that budget so pruning never silently destroys favorites or
unfinished work.

This persistence change covers EDSGER's conversation composer. The IDE composer
continues using its existing session draft.

## Pinned history

Swipe right on a history row or long-press it to Pin/Unpin. Pinned rows use a small
blue pin in their existing icon circle. The action is also available as a
VoiceOver custom action, and reordering respects Reduce Motion.

Pinned chats stay above recent chats, newest pin first. Their order stays stable
when messages arrive; pinning does not change activity timestamps, selection,
drafts, or an active response. Unpinning returns the chat to its normal recency
position. Search filters the same ordered list.

The optional `pinnedAt` timestamp is stored with each conversation using the
existing atomic history write. Older files without the field decode as unpinned.
Favorites survive reopening and history pruning; deleting a favorite still
deletes that conversation. New Chat does not reuse a pinned empty conversation.

Portable regression checks cover legacy files, persistent pin/unpin, ordering
after activity and generation, multiple pins, pruning, deletion, selection/draft
preservation, and invalid IDs. Actual swipe/context-menu behavior still requires
iPhone or simulator verification.

## Scrolling

Text chat and both IDE transcript presentations use `ConversationTranscript`.
It follows new content while pinned to the latest messages, pauses during touch
tracking/dragging/deceleration, and stays paused when the user finishes more than
80 points from the bottom. Growing content cannot independently turn following
off: scroll intent and proximity are separate values.

Scrolling back near the bottom resumes following. A Latest/New content button
provides an explicit return. Sending a new message and opening a different
conversation also move to the latest message. Keyboard/container size changes
follow only when following is already enabled; finishing a response does not
force a reader back down. Explicit jump animation respects Reduce Motion.

The view uses iOS 18 APIs (matching the app's minimum deployment target):
[scroll geometry](https://developer.apple.com/documentation/swiftui/view/onscrollgeometrychange(for:of:action:))
and [scroll phases](https://developer.apple.com/documentation/swiftui/view/onscrollphasechange(_:)).

## Generation status

Status callbacks report actual stage boundaries: waiting for the shared engine,
loading the model if needed, reading/preparing the request, generating text or
code, interpreting a calculation, and executing the calculator. Warm inference
does not report model loading. Direct arithmetic reports calculation without
inventing model work. Chat retains status alongside streamed text; the IDE keeps
its completion-review and tool-action statuses.

Callbacks are scoped to the current run. IDE callbacks also belong to one
inference pass, preventing a completed pass from overwriting the next tool step.
Stop, completion, and errors clear active chat status. These updates add no
inference requests, token generation, or artificial progress delays.

Agent completion contracts now live in the portable domain layer. Model smoke
tests and the macOS compile check use those same contracts rather than duplicate
definitions, reducing the chance of test/app interface divergence. The original
non-status methods remain available, with protocol defaults for older clients.

## Validation

Linux, optimized Swift 6.0.3, strict concurrency:

- `bash scripts/test-chat-experience.sh`: ten groups passed, covering separate
  Unicode/multiline drafts, transitions and reopen, send/rejection/delete,
  debounced writes and lifecycle flush, legacy history, protected retention,
  pin persistence/order/retention/deletion, live status/stop/stale
  callbacks/failure, calculator phase order, and the scroll-follow policy.
- Existing portable math suite: all 10 tests passed.
- Production `AgentSession` orchestration regression passed: immediate review,
  repair after failed runs, failed-write handling, and ordinary answers retain
  their expected inference call counts.
- Production inference/harness compiled with the corrected escaping-autoclosure
  OSLog host substitute. A real bundled-model cold and warm chat both returned
  `OK`. Cold stages were loading → preparing → generating; warm stages were
  preparing → generating.
- SwiftUI files passed Swift parser checks. Shell scripts passed syntax checks.

**The full iOS app was not built or run here.** This Linux environment has no
Xcode, Apple SDK, or iPhone. Parser/policy checks do not validate SwiftUI type
checking, layout, keyboard timing, or touch delivery. Run the real Apple logging
compile check with `bash scripts/check-local-inference-build.sh`, build the app
in Xcode, and verify these device scenarios:

1. Draft in chat A; create chat B and draft there; switch between them; background
   and reopen. Both drafts and the active chat should be restored.
2. Generate a long answer, scroll up during generation, and open the keyboard.
   Reading position should remain stable. Latest should return to the bottom.
3. Check a first-launch reply, a warm reply, direct `2+2`, and a planned integral.
   Status should describe the corresponding stages and disappear on stop/error.
4. Repeat scrolling and stop checks in the expanded and compact IDE transcript,
   including Reduce Motion and VoiceOver.
