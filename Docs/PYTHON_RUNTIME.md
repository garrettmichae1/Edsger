# Python in lilC

The iOS app embeds CPython 3.14.7 using BeeWare Python-Apple-support **3.14-b11**. Python is a separate Home workspace; C files stay in `Documents/lilC`, Python files in `Documents/lilPython`. The selected language and file persist independently. The agent has separate conversation histories and receives a short selected-runtime rule block in its existing request, without another inference call.

## Reproduce the bundle

Run `scripts/fetch-python-assets.sh` before opening/building Xcode. It downloads and verifies:

- [BeeWare release](https://github.com/beeware/Python-Apple-support/releases/tag/3.14-b11)
- Artifact: `Python-3.14-iOS-support.b11.tar.gz`
- SHA-256: `b591f3301bd22a4f423c49c746cac9e55558b909fd14d6eb8327ccc62234ab7b`
- Slices: arm64 iOS, arm64/x86_64 iOS Simulator; upstream minimum iOS 13, app minimum iOS 18.

The downloaded runtime is ignored by Git; the fetch script and licenses are tracked. Xcode links/embeds Python.xcframework. After Xcode embeds the core framework, the Bundle Python phase adds its privacy manifest and re-signs it, then copies the standard library, removes upstream test extensions, converts extension binaries to signed frameworks, and generates `.fwork`/`.origin` links. No dependency is downloaded at app runtime. This follows [CPython's iOS embedding and packaging guidance](https://docs.python.org/3.14/using/ios.html).

Dependencies from upstream VERSIONS: BZip2 1.0.8-2, libFFI 3.4.7-2, mpdecimal 4.0.0-2, OpenSSL 3.5.8-1, XZ 5.6.4-2, Zstandard 1.5.7-1. Notices ship in `Python-Licenses` and are readable in Settings → Licenses. The CPython standard library retains its source notices.

## Behavior

- `.py` files and modules, separate folders/projects, Python starter code and labels.
- Python syntax coloring, symbol row, and indentation on Return. C's brace formatter is hidden in Python.
- Run executes the selected script with its containing project as the working directory and import root.
- Fresh subinterpreter for every run prevents globals/imports carrying into the next run. Execution is serialized; initialization is reused.
- Console `print`, `input`, stdin reads/EOF, Unicode, tracebacks, and jump to source errors.
- Stop interrupts Python execution, input waits, and the console's interruptible `time.sleep`. Native extension calls may not stop until they return. Output is limited to 1 MiB per run.
- Bundled standard library and local modules; no pip UI, downloaded native packages, desktop GUI, network/process/thread APIs. `assert`-based tests work locally.
- Ordinary file access is restricted to the project and bundled library; project writes and data folders are supported. Low storage produces a visible write error.

Python runs in the app process, just as the C interpreter does. Audit hooks and disabled process operations are guardrails, **not a security boundary for hostile programs**. Programs can consume app memory; native calls and deliberately caught interrupts are not forcibly terminated. iOS does not offer this app a general-purpose child process for execution.

## Privacy and review

Privacy manifests accompany Python.framework and its OpenSSL-backed modules. File metadata is used for bundled imports/project files (`C617.1`), the runtime clock for elapsed-time/timers (`35F9.1`), and disk capacity for visible low-space write errors (`E174.1`). The app manifest also covers project file metadata and its own elapsed timing. No telemetry is added. See [Apple's required-reason API documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

This is local build preparation, not an App Store submission or assurance of approval. Before release, exercise the signed build on physical iPhone, run Organizer validation, and update the listing/review notes to describe the Python workspace and educational execution behavior.

## Verification

Unit coverage includes Python execution, local imports, fresh globals, Unicode input, errors, actual delayed Stop during loops/input/sleep, common native standard-library imports, separate workspace persistence/deletion, project data writes, and agent Python edit/run dispatch with the selected runtime rules. The UI test `testPythonLanguageSwitchAndRun` switches C → Python, creates/runs Python in the editor, and switches back to C.
