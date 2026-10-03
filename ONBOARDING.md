# Edsger introduction

Onboarding is a single scrollable page in the developer's voice. Its opening is **“Local AI. A developer who gives a shit.”** It states the environmental motivation and frustration with cloud AI CEOs, briefly explains local Chat and Agent plus math and coding, and commits to fixing bugs, listening to feedback, and improving local AI.

The screen uses readable typography and space, with no ASCII art, illustrations, cards, pagination, or feature carousel. A single **Let’s go** button remains available at the bottom, without requiring users to read everything first.

## Behavior

- First launch uses the existing `lilc.onboarding.completed` preference. Finishing dismisses onboarding and preserves the existing completion behavior.
- **Why Edsger** in Chat's Info sheet and Settings opens the same page. Its button reads **Done**, and replay does not change completion settings or user data.
- The page supports Dynamic Type, VoiceOver headings, dark/light appearance, and a capped reading width on iPad. The bottom button is outside the scrolling content and respects the safe area.
- There are no page transitions. The existing app-level completion transition respects Reduce Motion.

## Accuracy

The criticism of cloud AI CEOs and concern for the environment are the developer's stated position. The technical claim is that Chat and Agent perform inference locally without cloud AI requests, using the production defaults in `TutorSession`, `CalculatingTutorClient.shared`, and `AgentSession`. `LocalAgentClient` loads the bundled GGUF model, and math calculations run through `LocalMathCalculator`.

The introduction does not promise zero environmental impact or measured energy/carbon savings. A short note acknowledges device power use and that sharing/backups follow iOS settings. It does not claim that training or distributing the model never involved data centers.

## Verification

- Production onboarding copy/store passes Swift 6 strict-concurrency type checking.
- Modified Swift files pass syntax parsing, project/reference checks, and `git diff --check`.
- Existing native tests were updated for scrolling, immediate completion, replay dismissal, and rendering at phone/iPad sizes with both themes and normal/accessibility text sizes. Old page-navigation and ASCII-data assertions were removed.
- Native build, UI tests, and visual verification remain unrun because the host has no Xcode/iOS SDK. Run those checks in Xcode before release; syntax parsing cannot validate SwiftUI types or layout.
