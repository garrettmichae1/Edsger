# Agent panel presentation

The agent remains inside the editor output panel. Compact and expanded layouts
share one transcript/composer view; the optional standalone agent screen uses
the same view. Tools, execution, safeguards, saving, history locations, and the
wire transcript retain their existing behavior.

- Remove the permanent logo, repeated AGENT/YOU labels, on-device subtitle, and
  idle Ready status. Use regular text, right-aligned user bubbles, the chat's
  Markdown/code/math renderer, and tighter spacing.
- Render the legacy introductory message as a small empty state. Filter it only
  before the first user request; leave saved history and real responses intact.
- Show working status at the end of the transcript. Keep stop/error outcomes
  visible, and preserve the send/stop button. Return in a field does not stop a
  running task; the explicit stop button still does.
- Present tools as compact disclosure rows. Successful edits use the actual
  workspace result and filename; failed/rejected edits show expanded details.
  Run results use the neutral label “Run output”: a finished run does not prove
  the code passed. Full original output remains selectable under each row.
- Give the composer its own opaque background, separator, rounded input, and
  44-point send/stop target. Remove the transcript's fixed minimum height and
  prevent running-console intrinsic sizing from stretching the agent panel.
- Use Edsger in agent UI, the root editor title, and the agent identity prompt. Keep existing storage
  paths, bundle names, and StoreKit product identifiers for compatibility.

## Scrolling

`TranscriptScrollState.endInteraction()` now ignores idle events when no user
gesture occurred. Programmatic scrolling and panel resizing also end in idle;
previously they could turn off following because the new viewport briefly put
the bottom outside the visible region. The shared transcript initially anchors
to the bottom. Readers who scroll into older history retain their follow
preference when resizing; the Latest button resumes following explicitly.
This corrects the same edge case in text chat without changing its styling.

## Validation

`bash scripts/test-agent-presentation.sh` compiles production presentation and
scroll policy with Swift 6 complete concurrency checks. It covers saved-message
round trips, legacy onboarding, identity/order, actual vs failed mutation labels,
Unicode paths, neutral run results, unknown tools, and viewport/follow behavior.
Swift parser checks cover changed UI/session files; the project-reference checker
continues to validate the editor dependencies. These are host checks, not an iOS
UI build or visual verification.

Xcode, UIKit SDKs, and a simulator/device are unavailable in the Linux workspace.
Before release, build the app in Xcode and verify both panel sizes, keyboard
appearance/dismissal, long input, Dynamic Type, VoiceOver, Markdown/code output,
long activity details, failed tools, Stop, and scrolling while reading older
messages or following new activity. Resize while a program is running as well.
