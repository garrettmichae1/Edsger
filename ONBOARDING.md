# Edsger onboarding

The first-run experience introduces the current app in four short pages:

1. **Privacy:** Chat and Agent run on the device with the bundled AI model.
2. **Chat:** conversations, local math calculations, pins, and saved drafts.
3. **IDE:** supported C, Python, JavaScript, and Lua programs; editor assistance and project files.
4. **Agent:** editing and running in the output area, project checkpoints, new chats, and conversation history.

Each page has restrained ASCII artwork, a headline, a short explanation, and two feature rows. Courses, subscription promises, the old lilC logo, and decorative looping animations are absent from the tour.

## Messaging and its limits

The selling point is **“Your AI. Your device.”** The tour says that local replies need no cloud AI data-center compute. This describes the inference path; it does not claim zero electricity use, zero environmental impact, or measured carbon savings. The device still consumes energy, and training/distributing the bundled model is outside this claim.

The implementation evidence is in the production defaults:

- `TutorSession` uses `CalculatingTutorClient.shared`, which uses `LocalAgentClient.shared` for chat and calculation planning and `LocalMathCalculator.shared` for calculations.
- `AgentSession` uses `LocalAgentClient.shared`.
- `LocalAgentClient` loads the bundled GGUF model through llama.cpp; it has no remote inference fallback.
- `LocalMathCalculator` runs the bundled Python/SymPy engine locally.

The legacy `OpenAICompatibleAgentClient` exists in the repository but is not selected by these production defaults. Future changes that introduce cloud inference must update the tour's privacy copy as part of that change.

The privacy page explicitly distinguishes local AI from sharing and device backups, which follow the user's iOS settings. It does not describe the entire app as network-free or promise that backed-up or shared files can never leave the device.

## Navigation and accessibility

- Continue and swipe advance through the tour. Get started completes it on the last page.
- Back returns to the preceding page; Skip is available on every page.
- Chat → Info → **Take the Edsger tour** opens the same experience with Done controls. Replaying does not alter the completion flag or any conversations, settings, or files.
- The existing `lilc.onboarding.completed` key remains intact. Existing users are not forced through the tour again.
- Every page scrolls independently to accommodate small screens, landscape, and accessibility text sizes. Navigation remains outside the scroll area.
- Typography scales with Dynamic Type. ASCII art uses a fixed monospaced font and smaller variants when space is limited.
- VoiceOver skips decorative punctuation, combines each feature row, identifies page headings, and can adjust the page indicator. Buttons have at least 44-point targets.
- Light mode uses darker secondary ink for readable descriptions. Both themes use the existing app palette.
- Programmatic page transitions and the first-run exit respect Reduce Motion.

## Validation

Host verification on Linux:

- Production `OnboardingStore` and its new page data compile with Swift 6 strict concurrency. A temporary executable checks completion persistence, existing-user migration, interrupted onboarding, independent folder-tip state, and ASCII page data.
- Modified Swift files pass the Swift parser. The Xcode project/reference checker and `git diff --check` pass.

Native checks included in the existing test targets, **not executed on this Linux host**:

- `onboardingViewRendersInLightAndDark`: every page at 320×568, 393×852, and 1024×768, in both themes, at normal and accessibility text sizes. This checks rendering availability, not visual correctness.
- `testOnboardingNavigationAndCompletion`: forward/back navigation and completion.
- `testOnboardingCanSkipFromEveryPage`: each page's skip path.
- `testOnboardingReplayReturnsToInfo`: replay and return to the Info sheet.
- Existing completion/skip persistence and folder-tip tests remain in place.

Before release, run the app and test targets in Xcode. Inspect all pages on a small iPhone and iPad in portrait/landscape; test large text, VoiceOver, Reduce Motion, swiping, replay, and relaunch after both completion and skipping. Linux parsing does not type-check SwiftUI against the iOS SDK or replace an iOS build.
