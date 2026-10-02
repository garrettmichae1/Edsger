# Language runtime shortlist for lilC

Research date: October 1, 2026. Scope: research only. No runtime was installed, bundled, built, or integrated; no app functionality was changed during this task. Recommendations assume the existing native iOS 18+ app, offline student programs, and ordinary App Store distribution.

## Recommendation

**Choose embedded CPython through BeeWare Python-Apple-support for Python.** Next, evaluate QuickJS for JavaScript and Microsoft's TypeScript compiler running over the same JavaScript engine. Add Lua and Chibi-Scheme when there is curriculum value. Keep Java as a separate prototype using TeaVM's browser compiler; defer Haskell.

For this app, “compiler” needs to mean a complete source-to-execution solution. A compiler that produces an iPhone application on a development Mac does not let a student edit and run new programs inside lilC. Interpreters and bytecode virtual machines are appropriate here.

Ratings below are engineering judgments from upstream documentation, not results of device testing or promises of App Store acceptance.

| Language | Preferred candidate | Recommendation | Main integration issue |
|---|---|---|---|
| Python | CPython + BeeWare Apple support | First addition | Native package signing, interruption, memory and workspace isolation |
| JavaScript | QuickJS; compare Apple JavaScriptCore | Strong next candidate | Console/module bindings and dependable Stop behavior |
| TypeScript | Official JavaScript-distributed TypeScript compiler + chosen JS engine | Add alongside/after JavaScript | Full type checking needs virtual files and declaration libraries |
| Lua | Official Lua interpreter | Good smaller addition | Restrict host libraries and provide instruction-budget cancellation |
| Functional language | Chibi-Scheme | Best early functional candidate | Scheme curriculum and limited host bindings |
| Java | teavm-javac + TeaVM runtime in WKWebView | Prototype before committing | WebAssembly GC baseline, class library scope, licensing and cold-start cost |
| Haskell | Hugs 98 research prototype | Defer | Legacy language/library support and maintenance burden |

## What App Store compatibility actually requires

Apple's guideline 2.5.2 restricts code that changes app functionality and provides a limited exception for educational coding apps. App-provided source must be visible and editable under that exception. My recommendation is to keep student and AI-generated programs in the editor, bundle the engines with reviewed app releases, and scope execution to the advertised learning environment. No engine is independently “App Store approved”; Apple reviews the finished implementation. [Apple guidelines](https://developer.apple.com/app-store/review/guidelines/#software-requirements)

Do not base the design on an entitlement to JIT arbitrary native code. Apple's runtime security documentation describes tightly controlled executable-memory privileges. Use an interpreter, or supported system WebKit execution, without private APIs or entitlement workarounds. Compiling to interpreted bytecode is different from installing a freshly generated native executable. [Apple runtime security](https://support.apple.com/guide/security/security-of-runtime-process-sec15bfe098e/web)

For the first multilingual release, I recommend a bundled library set and no general-purpose package installer. This is a product/review-risk choice, not a claim that every pure-source package download is forbidden. Preserve license notices and audit each shipped dependency, not only the top-level engine.

## Python: CPython is the best fit

CPython's own iOS documentation describes embedding the interpreter in Swift/Objective-C apps, including XCFramework integration, packaging extension modules into signed frameworks, an App Store compliance patch, and privacy manifests for affected dependencies. This is substantially stronger evidence than an unofficial iOS port. [Python's iOS guide](https://docs.python.org/3.14/using/ios.html)

BeeWare supplies the Apple packaging/build infrastructure, device and simulator slices, and an integration guide. Its current main branch targets Python 3.14. Use a pinned stable release and checksums after the prototype passes; do not follow a moving branch in production. Manual integration into the existing Xcode project is possible, so adopting a new app UI framework is unnecessary. [Python-Apple-support](https://github.com/beeware/Python-Apple-support), [integration instructions](https://github.com/beeware/Python-Apple-support/blob/main/USAGE.md)

Proposed first scope: ordinary Python console programs, project modules, input/output, exceptions, and an explicitly tested standard-library subset. Add scientific packages individually later. iOS Python cannot provide desktop subprocess/multiprocessing behavior; do not promise unrestricted pip, desktop wheels, terminal utilities, or the complete desktop ecosystem. [Python platform restrictions](https://docs.python.org/3/library/intro.html#ios-availability)

Licensing: Python uses the PSF license and includes additional component notices; BeeWare's support project uses MIT. Keep both sets and those of any bundled native dependencies. [Python license](https://docs.python.org/3/license.html), [BeeWare repository](https://github.com/beeware/Python-Apple-support)

**Important engineering gate:** prove Stop works without corrupting later runs. An embedded native interpreter shares the app process; putting it on a worker thread does not create a security boundary. Python-level import filtering is not a robust sandbox. Test runaway allocation, caught interrupts, blocking extension calls, file access, and repeated runs before deciding how broad the available modules can be. This is a design requirement for the prototype, not something verified tonight.

Alternatives:

| Python candidate | Why consider it | Why it is not my first choice |
|---|---|---|
| MicroPython | Compact embedded interpreter, MIT core | Documented CPython differences make general Python lessons and packages less predictable. Better for an explicit microcontroller track. |
| Pyodide | Python/WebAssembly with a documented worker execution model | Adds WebKit/worker/file-loading integration to a native app. Worth comparing if reset/isolation and future browser reuse outweigh native integration simplicity. Bundle assets locally rather than relying on the example CDN. |

Sources: [MicroPython differences](https://docs.micropython.org/en/latest/genrst/index.html), [MicroPython license](https://github.com/micropython/micropython/blob/master/LICENSE), [Pyodide workers](https://pyodide.org/en/stable/usage/webworker.html), [Pyodide license and included notices](https://github.com/pyodide/pyodide/blob/main/LICENSE).

## JavaScript and TypeScript: two languages sharing one runtime

**QuickJS is my preferred prototype for a console learning environment.** It is embeddable C with modern JavaScript features and MIT licensing. Its API exposes memory limits, stack limits, and interruption callbacks—useful for learner programs containing infinite loops. Build and sign the engine with the app; execute student source inside it. Expose narrow console/input/project-file functions instead of its unrestricted host OS helpers. [QuickJS documentation](https://bellard.org/quickjs/quickjs.html)

**Apple JavaScriptCore is the strongest alternative.** It already provides a system framework and `JSContext` source evaluation, avoiding another bundled engine. Before choosing it over QuickJS, prove cancellation and recovery using supported public APIs. JavaScriptCore alone is not a browser DOM or Node.js environment; describe exactly which host APIs lilC supplies. [Apple JSContext](https://developer.apple.com/documentation/javascriptcore/jscontext), [public header](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContext.h)

**TypeScript:** bundle a pinned release of Microsoft's JavaScript compiler distribution and run the emitted JavaScript in the chosen engine. `transpileModule` handles source transformation, but a useful TypeScript classroom environment should also use the Program/language-service APIs for semantic diagnostics, with bundled `lib*.d.ts` declarations and a virtual file host. Transpilation alone must not be advertised as full type checking. No Node installation is inherently required for an in-memory compiler host. Engine compatibility and startup cost still need a prototype. [Compiler API](https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API), [Apache-2.0 license](https://github.com/microsoft/TypeScript/blob/main/LICENSE.txt)

## Java: feasible candidate, higher integration cost

**First prototype: teavm-javac.** This upstream project specifically compiles Java source offline in the browser: it combines an OpenJDK compiler and TeaVM, exposes source files and diagnostics, and generates executable WebAssembly. This solves more of our problem than a tool that only cross-compiles our own app at build time. Bundle the compiler, class-library assets, loader, and worker locally in WKWebView. Treat that packaging as proposed, not already demonstrated on iOS. [Project and license notes](https://github.com/konsoletyper/teavm-javac)

Its project is Apache-2.0, but the OpenJDK components have GPLv2 with Classpath Exception obligations; the exception does not erase obligations for redistributing those components. Review the final artifact inventory and source-distribution requirements before bundling. [Upstream legal terms](https://openjdk.org/legal/gplv2+ce.html)

TeaVM's WebAssembly GC runtime needs matching browser capabilities. WebKit added Wasm GC in Safari 18.2, so lilC's current iOS 18.0 minimum cannot be assumed sufficient. Gate the feature or reconsider the minimum after testing the exact build on device. Test all required Wasm features, not GC alone. [TeaVM loader](https://teavm.org/docs/wasm-gc-backend/loader.html), [WebKit 18.2](https://webkit.org/blog/16301/webkit-features-in-safari-18-2/)

Do not market this as a full desktop JDK. TeaVM has different constraints around reflection, dynamic behavior, and platform APIs; validate collections, exceptions, generics, input, and multi-file beginner projects against the intended lessons. [TeaVM overview](https://teavm.org/docs/intro/overview.html)

Other candidates:

- **CheerpJ:** browser JVM worth considering if broader compatibility becomes essential. Its free CDN usage is not permission to redistribute an offline copy in lilC; self-hosting and OEM/redistribution require commercial arrangements. Confirm source compilation, iOS WebKit performance, and offline redistribution with the vendor before choosing it. No vendor contact was made. [Licensing](https://cheerpj.com/docs/licensing)
- **DoppioJVM:** MIT JavaScript/TypeScript JVM with a Java 8-era build setup. Interesting research reference, but I would not select it over the more directly applicable TeaVM compiler prototype without a maintenance and compatibility investigation. The class library also needs its own license review. [Doppio](https://github.com/plasma-umass/doppio)

## Functional languages and another inexpensive addition

**Chibi-Scheme:** the best candidate if the goal is teaching functional programming rather than Haskell specifically. Upstream describes a small embeddable C library, R7RS-small support, separate VM heaps, and known iOS operation. It supports higher-order functions, recursion, lists, and lexical scope. Inspect its permissive license and module notices in the selected build. This is Scheme, not a substitute implementation of Haskell. [Project](https://github.com/ashinn/chibi-scheme), [license](https://github.com/ashinn/chibi-scheme/blob/master/COPYING)

**Haskell:** Hugs is an interpreter suitable for exploring a bounded Haskell 98 learning track, but the upstream release page remains centered on September 2006. Its age and language/library gap make it a maintenance commitment, not a ready modern Haskell option. [Hugs documentation](https://www.haskell.org/hugs/pages/hugsman/index.html), [releases](https://www.haskell.org/hugs/pages/latest.htm), [license](https://www.haskell.org/hugs/pages/users_guide/license.html)

GHC's JavaScript/Wasm backends are useful technology, but compiling Haskell to a browser target does not automatically put the compiler itself on the phone. Even documented browser GHCi arrangements involve host-side tooling; a complete offline source-editing workflow must be established separately. I found no comparably straightforward candidate to recommend for production Haskell tonight. [GHC Wasm guide](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/wasm.html)

**Lua:** a strong additional small language with an official embeddable interpreter and MIT license. Prefer standard Lua for this evaluation, supply only intended libraries, and implement cancellation via supported interpreter hooks. Useful for scripting lessons, although it should not displace Python in priority. [Lua overview](https://www.lua.org/about.html), [license](https://www.lua.org/license.html)

## Decision and later prototype gates

Suggested order: **Python → JavaScript + TypeScript → Lua or Scheme → Java pilot → reconsider Haskell.** Language count alone is a weak release criterion; each advertised language should reliably support its lessons, diagnostics, input, Stop, and AI-generated code.

When implementation is authorized, use one common runtime contract for run/input/output/diagnostics/cancel and expose each language's limitations to the agent. Load the selected runtime on demand. Test memory pressure together with the existing 4B model, not just the interpreter in isolation.

Before bundling any candidate:

1. Run representative lessons offline on a physical minimum-supported iPhone, including syntax errors and multi-file imports.
2. Verify Stop, runaway loops, output flooding, memory exhaustion, input cancellation, and a clean subsequent run.
3. Check project-file boundaries, native bridges, network behavior, and failure isolation.
4. Measure actual app-size increase, cold/warm startup, and peak memory with the AI loaded. No candidate sizes or performance figures were measured in this research.
5. Pin versions, retain applicable source/notices, verify signed native modules and privacy manifests, and prepare transparent educational-execution review notes.

Tonight's decision-ready shortlist is CPython/BeeWare, QuickJS, the official TypeScript compiler, Lua, and Chibi-Scheme. Java remains a credible but unvalidated browser-runtime prototype; Haskell remains deferred. Nothing has been bundled pending that decision.
