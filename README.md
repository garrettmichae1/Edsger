# lilC

**Code in C, Python, JavaScript, and Lua on iPhone.**

lilC is a free student resource. You write C in a native editor, press Run, and PicoC interprets the program on this iPhone. There is no remote Linux VM, no SSH session, and no cloud compiler. C lessons stay free. The iPhone app can unlock an optional offline Linux course.

An optional agent mode runs a bundled Qwen3.5-4B model on the iPhone. It can help edit the current C project and run PicoC without sending code to a cloud model.

<p align="center">
  <img src="./Docs/screenshots/01-home.png" width="165" alt="Home — Learn C on iPhone">
  <img src="./Docs/screenshots/02-lesson-blank.png" width="165" alt="Lesson: replace ??? then press RUN">
  <img src="./Docs/screenshots/03-hello-run.png" width="165" alt="RUN prints hello from lilC">
  <img src="./Docs/screenshots/04-error-jump.png" width="165" alt="Syntax error you can jump to">
  <img src="./Docs/screenshots/05-settings.png" width="165" alt="Settings — PicoC, Light or Dark">
</p>

<p align="center">
  Home · fill <code>???</code> · Run · jump to errors · Settings
</p>

## Try it now

**[Run C in your browser](https://garrettmichae1.github.io/lilc/web/)** — free, no install, no account. PicoC in WASM, not GCC.

On iPhone: tap **Open editor**, then **RUN**. `hello.c` is already there.

Source is open at [github.com/garrettmichae1/lilc](https://github.com/garrettmichae1/lilc).

## Write. Run. See.

Open a First Hour lesson, replace `???`, and press **RUN**. Output appears on the same screen. Find in file, a symbol keyboard, and jump to error are included. Files and projects stay on this iPhone. You can erase them from Home or from Settings.

## PicoC, honestly

The runtime is **PicoC**, a small interpreter (BSD 3-Clause, vendored in this repository). It is not GCC or Clang. Most beginner programs work. A full standard library, or extras only a desktop compiler supports, will not.

When a program fails, lilC shows a note written for learners. Tap **ERROR** to jump the caret to the line.

## Light and Dark

Settings stores Light or Dark in UserDefaults. The chrome is spare on purpose: paper or black, one accent, readable type. The PicoC note in Settings is the same one this README uses.

## Open in Xcode

1. Clone this repository.
2. Run `scripts/fetch-agent-assets.sh`, `scripts/fetch-python-assets.sh`, and `python3 scripts/fetch-math-assets.py` to fetch the pinned model, inference framework, and CPython runtime.
3. Open `lilC.xcodeproj` (iOS 18 or later). For simulator builds, see [local agent setup](Docs/LOCAL_AGENT.md).
4. Select the **lilC** scheme and a simulator or device.
5. Build and run.

```bash
xcodebuild -scheme lilC -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## What ships

| Surface | In this release |
| --- | --- |
| Editor | Find, symbol keyboard, jump to error |
| Run | Run, Stop, stdin while a program waits |
| Files | Projects on this iPhone, including erase all |
| Settings | Light, Dark, an honest PicoC note, legal links |
| Web | Same learner in the browser at `/web/` |
| Agent | On-device Qwen3.5-4B, available in the editor output panel |

Agent Mode and Syntax Color are on by default and can be switched off in Settings. Agent conversation history stays on the iPhone. See [local agent setup](Docs/LOCAL_AGENT.md) for model provenance and packaging.

## Legal

Privacy and Terms are live on GitHub Pages. Settings and App Store review use these URLs. Keep the HTML at the repository root so the paths stay stable.

| Page | URL |
| --- | --- |
| Home | https://garrettmichae1.github.io/lilc/ |
| Web app | https://garrettmichae1.github.io/lilc/web/ |
| Teachers | https://garrettmichae1.github.io/lilc/teachers.html |
| Privacy | https://garrettmichae1.github.io/lilc/privacy.html |
| Terms | https://garrettmichae1.github.io/lilc/terms.html |

The files are `index.html`, `privacy.html`, `terms.html`, and `styles.css`.

## Browser copy

A TypeScript copy of the editor is in this same repository, served as another GitHub Pages path (not a second GitHub user):

https://garrettmichae1.github.io/lilc/web/

Built files live in `web/`. Source lives in `apps/web/` (Desktop folder: `lilCWeb`). It does not change the iPhone app. Privacy and Terms stay at the root URLs above.

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) if you want to add a PicoC library, a diagnostic, or an editor extra, and how to send a pull request.

## License

lilC source (except vendored PicoC) is **Apache License 2.0**. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

You may use, modify, and fork the **code**, including in other projects. You may not publish or sell the lilC app (same or confusing name, icon, or bundle id) on the App Store or any other store. Forks must be renamed. See [TRADEMARKS.md](TRADEMARKS.md).

PicoC remains BSD 3-Clause (`lilC/Vendor/PicoC/LICENSE`).

## Python workspace

Use the ASCII language picker on Home to switch between independent C and Python files, projects, and agent histories. Python runs locally with CPython 3.14.7: `.py` editing, indentation, local imports, console output, `input()`, Stop, and traceback navigation. C lessons remain in the C workspace. Python supports the bundled iOS standard library, not pip downloads or desktop GUI/process libraries. See [Python runtime](Docs/PYTHON_RUNTIME.md) for packaging, limitations, and validation.

## JavaScript and Lua workspaces

Home also offers JavaScript (Apple JavaScriptCore) and Lua 5.5.1. Each has separate projects, source files, console input/output, local modules, syntax highlighting, and language-aware agent instructions. Their small dependencies are vendored, so no additional fetch step is needed. See [JavaScript and Lua environments](Docs/JAVASCRIPT_LUA.md) for console APIs and runtime limits.

## EDSGER

**EDSGER** opens on launch as a free offline teaching chat for C, Python, JavaScript, Lua, and other academic subjects. It shares the bundled model, streams text responses, and saves conversations locally. The **Courses** tab retains existing lessons, while **IDE** opens the project home screen. It has no coding-agent tools and cannot modify project files. See [EDSGER](Docs/EDSGER.md).
