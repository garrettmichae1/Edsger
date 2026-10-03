# Edsger Settings

Settings now follows Chat's white/near-black background, quiet rounded surfaces, system typography, and restrained blue accents. Content is centered and capped at 640 points on iPad. Controls and descriptions support Dynamic Type; appearance choices stack vertically at accessibility sizes.

## Groups

- **Appearance:** Light and Dark choices with small chat previews and an explicit selected state.
- **Editor:** syntax highlighting and a collapsed Runtime row. Expanding it reveals one brief, language-specific note.
- **Agent:** enable Agent mode and optionally block its file/folder deletion tools. The protection description makes clear that edits remain possible.
- **Workspace:** the active language's file count and a confirmed erase action. The confirmation explicitly includes project folders and identifies the language scope. Erasing is disabled during a running program, with a second guard in the confirmation action.
- **About Edsger:** reopen the “Why Edsger” introduction, write a review, and open privacy, terms, and open-source licenses. Existing release-gated support links retain their visibility policy.

The Linux course purchase, restore, and debug controls have been removed from Settings. Settings no longer takes a course store or performs course product loading. The root view's unused course store and startup loading task have also been removed. Course data and entitlements are not erased.

Existing appearance, syntax highlighting, Agent, and safeguard preference keys remain unchanged. The licensing text and legal destinations are preserved. Introduction replay uses the same onboarding view and does not reset its completion flag.

## Verification

- Modified Swift files pass syntax parsing with the available Swift toolchain.
- The Xcode project/reference checker and `git diff --check` pass.
- The existing Settings screenshot test now selects the C workspace explicitly, checks the compact runtime row, and checks that the expanded explanation and course section are absent on entry.
- The obsolete test for the removed, long PicoC copy constant was removed. Runtime and agent-rule tests remain intact.

This environment has no Xcode or iOS SDK. Native compilation, screenshots, and UI tests have not been run. Before release, verify Light/Dark selection, syntax coloring, Agent and safeguard toggles, runtime disclosure, introduction replay, legal links/licenses, and erase cancellation in Xcode. Check a small iPhone and iPad, including accessibility text sizes and VoiceOver. Confirm that changing appearance and leaving/reopening Settings retains the selected preferences.
