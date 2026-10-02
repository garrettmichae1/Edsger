# JavaScript and Lua workspaces

JavaScript uses Apple's system JavaScriptCore framework. Lua embeds the official Lua 5.5.1 C sources. Both execute offline on a worker thread and use independent project folders, selected-file preferences, and agent conversations. C and Python storage is unchanged.

## Bundled provenance

- Lua: https://www.lua.org/ftp/lua-5.5.1.tar.gz
- Official checksum: `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce`
- Sources in `lilC/Vendor/Lua`; built with `LUA_USE_IOS`. Standalone CLI, native package loader, debug library, and all-library initializer are excluded from the target. Upstream files are otherwise unmodified.
- Acorn parser 8.15.0: https://registry.npmjs.org/acorn/-/acorn-8.15.0.tgz
- npm SHA-512 integrity: `sha512-NZyJarBfL7nWwIq+FDL6Zp/yHEhePMNnnJ0y3qfieCrmNvYct8uvtiV41UvlSe6apAfk0fY1FbWx+NwfmpvtTg==`
- Acorn is bundled locally to parse JavaScript before adding cooperative checkpoints. No package manager or runtime download is used.
- Both MIT notices are copied to the app and displayed in Settings → Licenses.

## JavaScript environment

`.js` scripts support `console.log/error/warn`, `print`, synchronous `input(prompt)` (returns null at EOF), local CommonJS `require('./helper')` with `module.exports`, and project text `readFile(path)` / `writeFile(path, text)`. Each run has a new JavaScriptCore context. This is not Node.js or a browser: no npm, DOM, fetch, timers, or ES module imports. ECMAScript 2025 parser syntax is accepted subject to the installed iOS JavaScriptCore engine's support.

The public JavaScriptCore API has no hard cancellation API. The app parses code with Acorn and inserts checkpoints into loops and functions, without rewriting strings or comments. Stop is cooperative: long native operations (for example a pathological regular expression) and deliberately caught interrupts can delay it. Dynamic eval/Function constructors are disabled because they bypass checkpoints. The private `JSContextGroupSetExecutionTimeLimit` API is not used. Scripts are not a hostile-code security sandbox. Source URLs and line-preserving wrappers keep stack line numbers tied to project files; transformed columns are approximate.

## Lua environment

`.lua` scripts support the base, table, string, math, UTF-8, coroutine, console I/O, and restricted OS libraries. Local source modules use `require('helper')`; text-only `load`, `loadfile`, and `dofile` are available. File handles use `io.open` within the active project. `io.read` supports line, number, byte-count and all-input reads, plus EOF. `io.write`, print, and default stdin/stdout use the editor console.

OS process/exit/environment mutation, debug hooks, native loading, io.popen, and LuaRocks are unavailable. A VM instruction hook checks Stop, including coroutines. Lua allocation is capped at 64 MiB per run and console output at 1 MiB. A fresh Lua state is created for every run. Native library calls must return before the hook can interrupt them. File-path guards and restricted libraries are defense in depth, not process isolation.

## Verification and release

Unit tests cover actual engines, local modules, file access, Unicode input/EOF, syntax/runtime errors, Stop during loops/input, and language-specific workspace extensions. UI checks exercise selection, file creation, execution, and return to C. Run physical-device testing and Organizer/App Store validation before publishing; no update is automatically uploaded by these changes.

References: [Apple JavaScriptCore](https://developer.apple.com/documentation/javascriptcore), [Lua releases](https://www.lua.org/download.html), [Lua 5.5 manual](https://www.lua.org/manual/5.5/).

### Local validation, 2026-10-02

- 146 unit tests passed (159 executions including parameterized cases), covering C/Python regressions and both new runtimes.
- Both language-switch UI flows passed: JavaScript/Lua create and run, plus Python create/run and return to C.
- A signed iOS Release archive was built at `/tmp/lilc-four-languages-ready.xcarchive`; no upload was performed. Physical iPhone execution and App Store server validation remain release checks.
- JavaScript error filenames and lines, nested arrows/labeled-loop behavior, Lua coroutine cancellation and the 64 MiB allocation limit, and scripted agent edit/run flows have dedicated passing tests.
