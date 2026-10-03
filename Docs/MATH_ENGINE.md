# On-device chat calculations

Chat's calculation path uses `CalculatingTutorClient`. The tutor has no workspace or coding tools. The coding-agent dispatcher is unchanged. Active document questions use the separate bounded document path and do not run the calculator.

## Request flow

1. A broad local routing gate identifies math requests and contextual follow-ups. Plain numeric arithmetic (including “What is 2+2?”) goes straight to the calculator, without loading the model.
2. Other candidates use `LocalAgentClient.mathPlan` on the actor-owned Standard model/context for both chat model choices. A grammar-constrained pass returns a calculation, a clarification, an unsupported-operation message, or ordinary tutoring. Generation is capped at 512 tokens and 6 KiB. The last six whole messages are considered within an 8,000-byte context budget; missing context is not invented.
3. Swift validates operation, variables, expression size, and bounds. The trusted Python bootstrap independently validates the request and builds SymPy objects through an AST allowlist. User/model strings are never passed to `eval`, `sympify`, or `parse_expr`.
4. A successful calculation displays the interpreted input, exact result, and conditions. By default it stops there, skipping explanatory inference and any switch to Mini. Complexity alone never adds an explanation. Only the latest request's explicit explanation preference applies; an older request for steps is not sticky. "Explain"/"why" requests ask for two to four short sentences of prose describing the method, without worked equations or numerical approximations; "show the steps"/"derive"/a requested integration-by-parts method asks for one compact derivation, normally three to six steps. Explicit "answer only"/"no explanation" instructions suppress it. Additional detail remains available when explicitly requested.

   Short explanation follow-ups immediately after a successful calculator card replay the original user calculation request. Swift walks only a contiguous calculation/explanation exchange within six prior messages; unrelated conversation stops recovery. The planner receives history ending at that original request, excluding later calculator cards and generated explanations. This prevents bare "Explain briefly" from being classified as ordinary chat, and prevents a long earlier explanation from excluding the original expression from the planner's byte budget. Arithmetic still uses the direct fast path. Every replay recalculates through the existing calculator/cache: displayed answer text is never parsed or trusted as calculator input. Missing history or an unsuccessful replay asks for the expression again rather than falling back to an unverified answer. No new persisted context is introduced.
5. Explicit integral step requests now use **Worked steps · Calculated on device**, rendered directly from the existing SymPy `manualintegrate.integral_steps` rule tree. The calculator supplies fixed captions and equations; the language model never writes or rewrites this work. The ordinary answer is published first, then a separate optional work job uses the same bridge and cache with its existing execution budget. Swift requires the work response's interpreted input, exact answer and rendered answer to match the completed calculation. Missing, failed, oversized or unchecked work leaves that answer visible with a brief unavailable notice, without an AI derivation fallback. Task cancellation still propagates.

   This is deliberately bounded integration coverage, not a universal proof engine. The allowlist includes elementary constant/power/reciprocal/exponential/sine/cosine/arctangent rules, sums, constant multiples, integration by parts, algebraic rewrites, alternatives and substitution. Each evaluated rule is differentiated back to its integrand; parts setup and rewrite identities are checked. Intermediate expressions must remain defined across the original real domain or finite integration interval, including substitution back to the original variable. Endpoint evaluation must agree with the separately calculated answer. Unresolved checks, unlisted rule types, complex branches and narrower intermediate domains decline work conservatively. For example, a negative-interval reciprocal integral can keep its real answer while omitting a `log(x)` derivation. Displayed work includes selected setup/rewrite equations and the full antiderivative/final evaluation; it does not narrate every internal rule.

   Brief explanations and non-integral step requests retain the existing, separately labeled AI-generated path. Both chat choices reuse Standard already loaded for planning, with isolated calculation context and no extra resident model or verification pass. Normal Mini chat is unchanged. Instructions cannot verify these remaining AI explanations; failure preserves the calculator result and cancellation propagates. Natural-language request interpretation also remains model-dependent.

6. Unsupported/ambiguous requests are surfaced directly. Calculation failures do not fall back to an unverified numeric answer. Ordinary conceptual questions and requests for hints continue through the tutor.

## Supported operations

- Exact real arithmetic, fractions, decimals, powers, supported trigonometric/exponential/logarithmic functions.
- Simplify, expand, factor, first derivative, indefinite and finite-bound definite integration.
- One-variable polynomial/rational equations with numeric coefficients, through degree four, over the real numbers. Original denominator exclusions are retained, including when factors cancel.
- Determinant and inverse of numeric square matrices up to 4×4; rank and RREF of matrices up to 4×5, including augmented matrices.
- Mean, median, population/sample variance and population/sample standard deviation, up to 40 observations. Sample variance/deviation require at least two observations.

Matrix/data entries can be numbers or quoted numeric expressions such as `"1/3"`. Variables are `x,y,z,t,a,b,c,n`; constants are `pi,e`. Trigonometric arguments are radians. Clearly specified degrees can be translated to `angle*pi/180`; ambiguous units and sample/population choices should trigger clarification. `log`/`ln` are natural log in calculator syntax. The planner can express a specified other base through a log ratio.

The engine preserves original denominator, square-root and logarithm conditions in the response. Definite integration conservatively rejects intervals crossing undefined points. Rational real antiderivatives retain `log|u|` where appropriate. Derivatives may have a narrower domain than the input; the result notes this explicitly. Results are exact; there is no explicit rounding/approximation mode.

Limits, inequalities, general equation systems, complex-domain solving, eigenvalues, arbitrary symbolic exponents, factorials, plotting, units/conversions, and unrestricted tool chains are not supported. These are explicit scope limits, not a promise to solve every mathematical question. Users can request RREF for a small numeric linear system.

## Runtime and limits

`LocalMathCalculator` uses the existing C Python bridge with a dedicated warm interpreter, isolated from disposable IDE interpreters. The process-wide engine lock prevents concurrent Python execution. A busy engine returns immediately so a chat calculation does not wait behind IDE `input()`. The calculation cache holds up to 64 successful requests; ordinary and optional-work responses have separate keys. Answer-only and brief requests do not construct a rule tree or run the optional work job.

SymPy startup has a separate 30-second cooperative deadline. Every calculation receives a fresh 8-second budget after startup, checked through CPython tracing, plus task cancellation. Startup failures have a distinct message and do not tell the user to simplify a valid expression. Interrupted interpreters are discarded. Initial CPython setup/model loading and native C work cannot be forcibly interrupted mid-call. These are not hard process-level execution deadlines. Size and complexity bounds reduce native work: 400-byte expressions, 80-byte bounds, 120 AST nodes, nesting at most 16, numeric powers in −20…20, 4,096-bit rational intermediates, expansion budget 2,000 terms, bounded rendered output. Requests do not execute arbitrary Python or access files. Optional work additionally limits rule depth to 8, visited rules to 32, rendered steps to 6, each equation to 1,400 UTF-8 bytes and total work to 5,000 bytes. The complete native response remains within 16 KiB; oversized work is omitted. No new model weights, Python dependency or planner fields are added.

Both the arithmetic fast path and successful result display work without a model explanation. Model-driven natural-language planning still requires the bundled model. The interpreted input is always visible so users can catch an incorrect translation.

## Build setup

Run the existing runtime/model fetch scripts and:

```sh
python3 scripts/fetch-math-assets.py
```

The build verifies SHA-256-pinned SymPy 1.14.0 and mpmath 1.3.0 wheels and packages them offline. There are no runtime downloads. Wheel license metadata is retained in `math-packages`, and license copies are included in `Python-Licenses`.

## Validation

Portable checks:

```sh
python3 -m venv /tmp/edsger-math
/tmp/edsger-math/bin/pip install sympy==1.14.0 mpmath==1.3.0
/tmp/edsger-math/bin/python scripts/test-math-engine.py
/tmp/edsger-math/bin/python scripts/test-math-native.py
scripts/test-math-domain.sh
```

The native test needs host CPython development headers/library and a C compiler. It exercises the actual bridge for cold/warm use, a deliberately slow startup that does not consume the calculation budget, reuse across threads, deadlines, cancellation, recovery, and IDE isolation/contention. The domain script needs Swift 6 and runs the same routing tests included in the iOS unit target. The iOS serialized unit suite additionally exercises the bundled calculator without the language model.

On a Mac with the existing model and inference framework installed:

```sh
scripts/test-local-tutor.sh --planner
bash scripts/test-math-explanation-model.sh /path/to/mini.gguf /path/to/standard.gguf /path/to/python-with-sympy
```

This exercises the actual model's structured plans, including contextual follow-up and ambiguity handling. Model plans can still be incorrect; this is representative coverage, not exhaustive semantic verification.

The explanation smoke uses both chat choices, production planning/routing/explanation instructions, and the shipped Python bootstrap through host Python. It runs a real thread: an initial answer-only integral, a separate "Explain briefly", then a separate "Show the steps". It checks answer-only and integral work make zero explanatory calls, brief follow-ups make zero ordinary-chat calls and reuse Standard, and the integral keeps its exact result with the correct polynomial division. AI brief output is inspected manually; text/length assertions are regression checks, not mathematical proof verification. This host harness does not exercise the iOS C/Python bridge or establish device timing.

Host evaluation of the logarithmic integral found unreliable complex derivations from Mini. Math-only system-prompt variants also produced intermediate algebra errors with Standard, so the production path retains the established tutor instructions. Standard can still misstate an intermediate term even when the calculator card is correct. The default reply now excludes this unverified reasoning entirely; brief and non-integral explanations remain explicitly AI-generated. The bounded integral work path now uses calculator evidence instead of prompting the model to invent a derivation.

2026-10-03 host validation passed: Swift 6 strict-concurrency compilation, 15 math-domain tests, 10 Python calculator tests, 17 prompt-cache cases, model-selection tests, document-chat tests and chat experience regressions. The real-model smoke passed six requests across both chat choices: answer-only requests made zero explanation calls; requested explanations reused Standard. The sample brief response was 83 whitespace-separated words, and the requested derivation had six steps (201 words including LaTeX); its equations were manually checked against the exact result. These are representative checks. This Linux workspace exposes `/proc` in a different PID namespace; a host-only mapping of current-thread metadata reads to `/proc/thread-self/stat` was needed for the final chat regression run. No app code was changed for that host issue. Native Apple builds and device behavior remain untested here.

Before release, build in Xcode and run the app/unit tests on a simulator and a physical iPhone. Check cold/warm timing, memory pressure, stopping during planning/calculation/explanation, switching chats mid-response, and alternating IDE Python with chat. Host results do not establish iOS latency or device memory behavior.

Follow-up regression investigation (2026-10-03): with the shipped Standard planner, both separate "Explain briefly" and "Show the steps" requests after the correct logarithmic-integral card returned `notCalculation`, allowing ordinary Mini chat to contradict the exact result. The earlier six-request smoke appended explanation instructions to the original question and missed this separate-message path. The fix adds bounded original-request replay and preserves clarification, calculator failure and cancellation behavior. The updated 19-test domain suite passes, including repeated follow-ups after an explanation exceeding the planner budget, arithmetic replay, sample/population clarification context, unrelated-topic boundaries and missing history. The chat-experience harness compiles, but its execution could not be revalidated in this workspace because Foundation traps while reading thread metadata in the mismatched `/proc` namespace, even with the host-only metadata workaround. This does not establish a native app failure; Xcode/device validation is still required.

The revised threaded real-model smoke passed all six requests across both chat choices: default requests made zero explanation calls, follow-ups made zero ordinary-chat calls, and the calculator's exact integral result remained present. The brief response was four sentences and 95 whitespace-separated words; it still included setup notation despite the prose-only instruction, but avoided intermediate evaluation and conflicting approximations. The requested derivation used five steps (202 whitespace-separated words including LaTeX). The sample setup and worked equations were manually checked against `2*log(2)/3-5/18` (approximately `0.1843203426`). This validates the reported thread, not arbitrary AI-generated proofs.

Calculator-work follow-up (2026-10-03): the user's physical-device test exposed a Standard-generated derivation with incorrect polynomial division that contradicted the correct calculator card. Representative earlier model output did not establish reliability. Explicit integral steps now bypass explanatory inference entirely; the reported example renders five calculator-generated steps and returns `2*log(2)/3-5/18`. The regression suite includes backwards-compatible response decoding, no inference for integral work, unchanged answer-only/brief paths, mismatched work rejection, missing capability, failures/cancellation, and output bounds. Python coverage checks the actual rule output across integration families and variables, wrong/unknown rule rejection, real-domain fallback, reversed bounds, malformed flags and deadline propagation. Native coverage additionally generates this work through the production C bridge and recovers after an optional-work timeout.

This update passed 23 portable Swift domain tests, 14 Python calculator tests, the production native-bridge harness and Swift 6 strict-concurrency typechecking of the changed calculator/routing code. The six-request real-model smoke passed for both chat choices: answer-only and worked integral steps made zero explanatory calls; brief responses used one focused Standard call and no ordinary chat. Both generated work outputs were inspected and contained the correct five-step derivation. These CPU-host measurements include existing model planning and do not establish iPhone timing. An Apple-only test now checks the actual bundled work response, real-domain fallback and light/dark equation typesetting; it has not been run here because Xcode/UIKit are unavailable. The broader chat-experience harness remains blocked by the previously documented host Foundation metadata issue. Build and run the native tests in Xcode before release.
