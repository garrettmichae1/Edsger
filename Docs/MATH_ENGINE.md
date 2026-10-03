# On-device chat calculations

Chat's calculation path uses `CalculatingTutorClient`. The tutor has no workspace or coding tools. The coding-agent dispatcher is unchanged. Active document questions use the separate bounded document path and do not run the calculator.

## Request flow

1. A broad local routing gate identifies math requests and contextual follow-ups. Plain numeric arithmetic (including “What is 2+2?”) goes straight to the calculator, without loading the model.
2. Other candidates use `LocalAgentClient.mathPlan` on the actor-owned Standard model/context for both chat model choices. A grammar-constrained pass returns a calculation, a clarification, an unsupported-operation message, or ordinary tutoring. Generation is capped at 512 tokens and 6 KiB. The last six whole messages are considered within an 8,000-byte context budget; missing context is not invented.
3. Swift validates operation, variables, expression size, and bounds. The trusted Python bootstrap independently validates the request and builds SymPy objects through an AST allowlist. User/model strings are never passed to `eval`, `sympify`, or `parse_expr`.
4. A successful calculation displays the interpreted input, exact result, and conditions. By default it stops there, skipping explanatory inference and any switch to Mini. Complexity alone never adds an explanation. Only the latest request's explicit explanation preference applies; an older request for steps is not sticky. "Explain"/"why" requests ask for two to four short sentences; "show the steps"/"derive"/a requested integration-by-parts method asks for one compact derivation, normally three to six steps. Explicit "answer only"/"no explanation" instructions suppress it. Additional detail remains available when explicitly requested. Short contextual follow-ups like "Explain" and "Show the steps" can recover the prior calculation through the existing bounded planner and calculator/cache; no new persisted context is introduced.
5. Requested explanations are separately labeled AI-generated. Both chat choices reuse Standard, already loaded for math planning, with the existing tutor prompt and isolated calculation context containing the interpreted input, result, conditions, and latest user request; earlier speculative answers are excluded. This avoids switching to Mini for weaker derivations. Normal Mini chat retains its existing model and sampling settings. Explanations use the same owned runtime, greedy sampler, context, streaming and cancellation, with no extra resident model or verification pass. Other tutor clients retain the compatible reply fallback. Explanations are instructed to use one coherent method and acknowledge uncertainty rather than invent steps. Brief requests describe the method without intermediate evaluation; steps are provided only when requested. These instructions do not verify model reasoning or guarantee correctness. A failed explanation preserves the result; cancellation still propagates. The explanation and request interpretation are not mathematical proofs.
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

`LocalMathCalculator` uses the existing C Python bridge with a dedicated warm interpreter, isolated from disposable IDE interpreters. The process-wide engine lock prevents concurrent Python execution. A busy engine returns immediately so a chat calculation does not wait behind IDE `input()`. The calculation cache holds up to 64 successful requests.

SymPy startup has a separate 30-second cooperative deadline. Every calculation receives a fresh 8-second budget after startup, checked through CPython tracing, plus task cancellation. Startup failures have a distinct message and do not tell the user to simplify a valid expression. Interrupted interpreters are discarded. Initial CPython setup/model loading and native C work cannot be forcibly interrupted mid-call. These are not hard process-level execution deadlines. Size and complexity bounds reduce native work: 400-byte expressions, 80-byte bounds, 120 AST nodes, nesting at most 16, numeric powers in −20…20, 4,096-bit rational intermediates, expansion budget 2,000 terms, bounded rendered output. Requests do not execute arbitrary Python or access files.

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

The explanation smoke uses both chat choices, the production planning/routing/explanation instructions, and the shipped Python bootstrap through host Python. It checks answer-only requests make zero explanatory calls, requested brief/step explanations reuse Standard, and the example integral keeps its calculator result. Length tolerances, the example antiderivative and a known conflicting approximation are regression checks, not mathematical proof verification. Inspect generated steps manually. This host harness does not exercise the iOS C/Python bridge or establish device timing.

Host evaluation of the logarithmic integral found unreliable complex derivations from Mini. Math-only system-prompt variants also produced intermediate algebra errors with Standard, so the production path retains the established tutor instructions. Standard can still misstate an intermediate term even when the calculator card is correct. The default reply now excludes this unverified reasoning entirely; requested explanations remain explicitly AI-generated. Reliable verification of every worked step would require separate calculator-generated evidence or proof validation, rather than a promise based on prompt wording.

2026-10-03 host validation passed: Swift 6 strict-concurrency compilation, 15 math-domain tests, 10 Python calculator tests, 17 prompt-cache cases, model-selection tests, document-chat tests and chat experience regressions. The real-model smoke passed six requests across both chat choices: answer-only requests made zero explanation calls; requested explanations reused Standard. The sample brief response was 83 whitespace-separated words, and the requested derivation had six steps (201 words including LaTeX); its equations were manually checked against the exact result. These are representative checks. This Linux workspace exposes `/proc` in a different PID namespace; a host-only mapping of current-thread metadata reads to `/proc/thread-self/stat` was needed for the final chat regression run. No app code was changed for that host issue. Native Apple builds and device behavior remain untested here.

Before release, build in Xcode and run the app/unit tests on a simulator and a physical iPhone. Check cold/warm timing, memory pressure, stopping during planning/calculation/explanation, switching chats mid-response, and alternating IDE Python with chat. Host results do not establish iOS latency or device memory behavior.
