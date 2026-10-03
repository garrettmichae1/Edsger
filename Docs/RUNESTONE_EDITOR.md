# Native Runestone editor

EDSGER's iPhone/iPad editor now uses Runestone for native text layout, line numbers,
selection, undo, and incremental Tree-sitter highlighting. The existing
`CCodeEditor` SwiftUI contract remains the integration boundary. Projects, disk
storage, execution engines, stdin/output, the agent, and chat use their existing
systems.

## Reproducible dependencies

| Component | Version | Revision |
| --- | --- | --- |
| [Runestone](https://github.com/simonbs/Runestone) | 0.5.2 | `592434a103a4d1ab83e14f87ac6eef569dd7a99d` |
| [TreeSitterLanguages](https://github.com/simonbs/TreeSitterLanguages) | 0.1.10 | `15cf3a9ec3ab95e0d058b7df9f35619123c9e02d` |
| [Tree-sitter](https://github.com/tree-sitter/tree-sitter) | 0.20.9 | `98be227227af10cc7a269cb3ffb23686c0610b17` |

The app links Runestone and only the C, Python, JavaScript, and Lua language
products. The lockfile also retains the existing Markdown/math dependencies.
Runestone 0.5.2 includes the upstream Xcode 26.4 compilation fix. License notices
are bundled in `Runestone-LICENSES.txt` and displayed in Settings > Licenses.

## Behavior preserved

- Existing font, light/dark colors, syntax-coloring preference, and wrapped lines.
- The language-specific symbol toolbar, four-space indent/outdent controls,
  existing C formatter, and keyboard dismissal action.
- Case-insensitive literal search, match count, previous/next navigation,
  and selected-match highlighting. Search and error highlights coexist.
- Script newline indentation uses the existing Python/JavaScript/Lua rules.
  Character-pair insertion remains disabled to preserve literal typing.
- External file/AI edits update an active editor. Binding echoes do not replace
  keystrokes, and marked text is protected while UIKit composes input.
- Bulk edits use Runestone's undoable state transition, preserving source bytes
  exactly, including mixed line endings. Formatting and toolbar indentation are
  undoable; undo/redo writes through the existing saving binding.
- The native editor remains the same view across edits. Focus uses Runestone's
  `isEditing` because its inner text input owns first responder. A stale SwiftUI
  focus flag never dismisses the keyboard.
- Switching documents resets undo so one file cannot receive another file's
  contents through undo. Selection and scroll positions are remembered for a
  bounded set of documents during the editor's lifetime.

## Runtime diagnostics

Tree-sitter supplies syntax colors only. Its error nodes are not exposed as
compiler errors, and no desktop compiler/LSP assumptions are introduced.
Runtime restrictions and existing output explanations remain authoritative.

| Runtime | Location handling |
| --- | --- |
| PicoC | Existing friendly explanations and concatenated-source mapping; named headers/helpers resolve only to known project files. Its zero-based UTF-8 byte columns are converted to UTF-16 editor positions. |
| CPython | Innermost known project frame from the actual traceback; includes nested local modules. |
| JavaScriptCore / Acorn | The first known source frame; Acorn syntax columns reference original code. Runtime columns from injected stop checks are intentionally not used for precise navigation. Error-only metadata excludes program stdout. |
| Lua 5.5 | Original module error in the runtime header, including require() rethrows. Truncated long iOS-style paths must match one known project URL. The bridge's final error chunk excludes printed filenames. |

An error marker appears only in its own file and while the source snapshot from
that run still matches. Editing, deleting, or renaming a captured source clears
the marker and stale navigation. Starting a new run clears previous markers;
successful runs leave none. Unknown files, ambiguous paths, or invalid lines do
not produce a guessed highlight. Empty EOF lines remain navigable without an
out-of-bounds highlight. Tapping the console continues to reveal the mapped file
and error line using the runtime's column convention.

## Verification

`bash scripts/test-editor-support.sh` is a Linux host regression harness. It
compiles the production workspace and editor support under Swift 6 with complete
concurrency checking and links the same PicoC sources shipped in the app. It
also builds the shipped Lua bridge/runtime and captures seven real failures:
syntax, runtime, module, nested module, printed filename, long container path,
and multiline message. It checks Unicode/CRLF/EOF locations, selection arithmetic,
binding synchronization, C formatting, Python/JavaScript location formats,
persistence, and invalidation of source snapshots. Python/JavaScript platform
runner boundaries are stubs in this Linux harness; their actual iOS engines
are not executed by it.

`python3 scripts/check-editor-project.py` validates the Xcode object graph,
framework links, source/resource inclusion, and pinned revisions. Swift parser
checks cover modified UI files. The editor host suite and project checks pass.
The existing PicoC conformance suite passes 97 of 101 cases; its four existing
failures concern qsort, function pointers, comma expressions, and ternary
assignment side effects. No PicoC engine sources changed in this integration.
The existing chat regression passes its first two groups, then encounters the
Linux libdispatch environment failure described below; it did not complete.

The container's Linux libdispatch traps while trying to read its process metadata
when running the asynchronous MainActor/PicoC completion path. Host tests therefore
exercise the production runtime and diagnostic-state transitions synchronously.
The asynchronous completion path has been compiled with strict concurrency;
the iOS tests below exercise it on the intended platform.

**No Xcode, iOS SDK, simulator, or physical-device session is available here.**
Host tests and parsing do not establish that the complete iOS app builds or that
keyboard/accessibility gestures work on-device. No device performance improvement
is claimed without measurement.

Added/updated iOS tests in `lilCTests` cover all four parsers, exact source bytes,
AI updates and undo/redo through the saving binding, file isolation, runtime/search
overlays, C-format undo, and native view/keyboard stability. Existing UI flows
locate the editor by its stable identifier without assuming it is a UITextView.

Before release, run the lilC test scheme in Xcode and check on iPhone/iPad:

1. Type, paste, select, delete, indent/outdent, format, undo/redo, and dismiss the
   keyboard in every language; test a hardware keyboard and non-Latin input.
2. Search and navigate several matches while a runtime error is highlighted.
3. Open helpers/headers and nested modules through console error navigation;
   edit while a run is active and verify stale errors do not reappear.
4. Apply AI edits, save/reopen, switch files/languages, and change appearance or
   disable/re-enable syntax coloring. Check VoiceOver editing and navigation.
5. In a Release build, measure opening time, typing frame times, scrolling, and
   memory for 100 KB and 1 MB documents against the previous editor on the same
   device. Initial document state creation currently runs on the main actor;
   measure it before deciding whether large-file preparation needs a worker.
