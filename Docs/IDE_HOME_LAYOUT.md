# Rearrange the IDE home screen

Hold an icon for approximately 0.4 seconds, then drag it to another grid position.
Other icons shift to make room. Tap **Done** to exit rearranging and use the apps.
The six action icons and four language icons share one grid and retain their
existing artwork, actions and accessibility identifiers. The grid is ordered and
compacts icons into rows; it does not store arbitrary pixel coordinates or gaps.

Layout is saved after each successful drop and applies across languages and app
launches. Changing language still switches the corresponding existing workspace.
Moving New File, Delete, Editor, Chat or Settings never invokes the icon's action.
Taps are ignored in rearranging mode until Done. No project/file content, chat,
agent state or active language preference is changed by a move.

## Implementation

`IDEHomeLayoutStore` owns a versioned UserDefaults array of stable icon IDs under
`edsger.ide.home.order.v1`. It removes unknown/duplicate IDs and appends missing/new
icons on read, retaining the user's order across app updates. Each committed move
uses the final destination index and writes the complete array. Invalid/stationary
moves have no effect. The default order remains the existing six actions followed
by C, Python, JavaScript and Lua.

`IDEHomeGrid` hosts the existing SwiftUI icon artwork in native UICollectionView
cells. A long-press recognizer uses Apple's interactive movement API to lift,
preview insertion, track scrolling and commit the move. Model order is updated
only by the successful movement callback; preview changes do not write preferences.
Cancelling a gesture restores the original position. Leaving the screen,
backgrounding or a width change cancels active movement. The grid does not export
drag payloads, accept external drops or modify the file browser's drag behavior.

Relevant Apple contracts:
- [Begin movement](https://developer.apple.com/documentation/uikit/uicollectionview/begininteractivemovementforitem(at:))
- [End movement](https://developer.apple.com/documentation/uikit/uicollectionview/endinteractivemovement())
- [Cancel movement](https://developer.apple.com/documentation/uikit/uicollectionview/cancelinteractivemovement())

A small cell wiggle marks rearranging mode and stops when Reduce Motion is enabled
or the app becomes inactive. VoiceOver exposes Move earlier and Move later actions,
announces the resulting position, and preserves selected-language traits. Done is
an accessible button above the grid; extra bottom inset keeps it off the last row.

The feature is available to everyone in this release. Future Pro entitlement checks
can be applied at this presentation boundary without changing persistence or any
workspace/runtime APIs. There is no placeholder purchase flow or paywall.

## Verification

`bash scripts/test-ide-home-layout.sh` passed on Linux with Swift 6 strict concurrency.
It tests default order, moves in both directions across rows, a new store reloading
the saved order, stationary/out-of-range movement, obsolete/duplicate/malformed
preferences, missing app recovery, stable identifiers and preservation of the
selected-language preference. The harness compiles production language/file value
types separately from their unrelated native runtime dependencies.

`python3 scripts/check-editor-project.py` passed, including both new app source
memberships. Swift syntax parsing passed for the native grid, home integration and
UI test. A full Apple SDK type check/build and UIKit interaction cannot be run on
this Linux host.

`StoreScreenshots.testIDEAppReorderingPersistsAndKeepsActions` is an added Xcode UI
regression covering long-press movement, Done, saved positions after relaunch, and
C/Python Directory navigation. It has not been run here. Before release, run it on
an iPhone simulator/device and manually check dragging language icons into the
first row, taps during rearranging, edge scrolling on a small screen, gesture
cancellation/backgrounding, rotation on iPad, light/dark appearance, Reduce Motion,
VoiceOver moves, and opening all six existing actions after moving them.
