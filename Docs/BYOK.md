# OpenAI and Claude BYOK (iPhone)

Settings → BYOK accepts personal OpenAI and Anthropic API keys, loads the account's supported model catalog, and verifies a selected model with a non-mutating native tool round trip before saving. Chat and Agent IDE have model selectors. No Pro gate, provider-credit sales or purchase link is introduced.

## Direct connection and credential boundary

The iPhone connects **directly** to `https://api.openai.com/v1` or `https://api.anthropic.com/v1`. BYOK does not require an Edsger backend, Cloudflare deployment, relay salt, app authentication or shared quota. The old Worker BYOK route is retired with HTTP 410 without reading its request body or credentials; the existing shared-pool/GitHub routes are separate. There is no user-editable upstream URL, redirect following, account fallback or automatic provider retry.

Only user-supplied personal keys are used. No Edsger developer key is embedded in the app. Keys are stored in device-only iOS Keychain entries accessible while unlocked; no iCloud synchronization. Preferences contain only model/catalog metadata, consent and selections. A failed key replacement preserves the working credential. Removing a key retains the model selection and produces a missing-key error instead of changing paying accounts. Draft fields clear on dismissal/backgrounding.

OpenAI's general security guidance warns against exposing API keys in client applications and recommends server-managed secrets. This deliberate personal-BYOK design keeps the owner's key in native Keychain storage and sends it only to that provider; it is not a claim of provider endorsement or protection against a compromised device. Developer-funded API access must use a separate server design. Do not put keys in source, prompts, diagnostic output or documentation.

## Provider adapters and agent capabilities

`BYOKProviderClient` and `BYOKNativeCodec` implement account catalogs, native request/response conversion, harmless verification, sanitized billing/permission errors and bounded non-streaming responses. OpenAI Responses uses `store:false` and encrypted reasoning continuation. Claude Messages uses native tool_use/tool_result and automatic tool choice, compatible with current always-thinking models. Signed Claude thinking is echoed unchanged within the active loop; historical thinking is stripped when a new task changes system/project context. Native state is reused only for the exact same provider and model and must match canonical tool IDs, names and arguments.

Responses are bounded to 1 MiB, error bodies to 16 KiB, request bodies to 384 KiB, history to 180 messages, tools to 32 and returned calls to 8. The app validates an entire tool batch before actions, preserves call/result pairs, rejects unknown/truncated/duplicate calls and checks sharing consent before each model completion. Stop is cooperative and cannot retract a provider request or its billable usage. No monthly dollar budget is enforced by the app.

Agent IDE retains local project tools, checkpoints, read-before-edit checks, code execution, output, Stop and bounded SymPy calculations. Ordinary Chat retains document passages and math without project mutations. No provider-hosted browser, computer-use, shell, package installation or unrestricted Python tool is enabled. Incremental cloud text streaming is not included in this version.

## Native Python runtime hardening

The host registers `PySys_AddAuditHook` before CPython initialization. The authority lives in native memory and is tied to the actual interpreter, covering Python execution and finalizers. The bootstrap no longer defines a mutable Python audit policy. Restrictions check resolved paths, existing and dangling symlinks, parent traversal, raw descriptors, directory-fd operations, SQLite paths, unsafe imports, sockets/process operations, trace changes, built-in module recreation, secondary interpreter creation and preloaded thread entry points. Project file I/O and safe standard-library/local imports remain supported. Trusted bounded SymPy uses its separate interpreter; IDE policy cannot be disabled by changing bootstrap globals.

New installations default the existing deletion-tool safeguard on; explicitly saved user choices are preserved. This safeguard blocks deletion tools, not every mutation performed by a generated program. Review generated programs before running them and retain restore points. CPython remains in the app process: native audit hardening closes the demonstrated bypass and common routes but is not a formal security sandbox, process isolation or a guarantee against every interpreter/native-extension vulnerability. Cooperative cancellation does not guarantee interruption of a long native operation.

## Runtime documentation for all providers

The shared `read_runtime_guide(topic)` tool returns app-authored guidance for the active language's actual runtime: PicoC, CPython 3.14.7, Apple JavaScriptCore or Lua 5.5.1. Topics are `overview`, `files`, `modules` and `limits`, each below 3 KiB. Short existing runtime rules remain in the system prompt; full guides are never automatically inserted. The agent is told to fetch only an uncertain topic, once per task. Repeated fetches return a short reference instead of duplicating the guide. This shared tool registry/executor works for local agents and future cloud/premium providers without duplicating docs in provider adapters.

Maintain `AgentRuntimeDocumentation` and increment its version when runtime bindings change. Guidance describes app behavior, not a full language manual. On-device compiler/interpreter results remain authoritative.

## Validation and release checks

- `python3 scripts/test-python-safety.py` compiles and runs the actual native runner against a host CPython, including the original bootstrap-global bypass, built-in loader recreation, secondary interpreters, symlinks, unsafe imports, finalizers and ordinary programs. CI uses Python 3.14; host tests do not substitute for iPhone execution.
- `bash scripts/test-byok.sh` executes actual Swift domain/store/Keychain/transport/codec tests on macOS without live credentials. Fixtures cover both native tool round trips, model catalogs, credential routing, errors, consent, histories, limits and runtime guides.
- CI compiles the unsigned iPhone app and BYOK unit-test target, checks Swift syntax/project/privacy manifests and existing math/model regressions. iOS integration tests are compiled; simulator/physical-device execution is a separate release check.
- The Worker typecheck, retired-route regression tests and Wrangler dry-run cover packaging without deployment.

Before shipping, enter separate owner-controlled test keys in the app and verify both provider catalogs, tool tests, create/edit/run/output, docs access, boundaries, rollback, Stop, missing/revoked keys, consent withdrawal and billing limits on a physical iPhone. OpenAI keys require models-read and Responses-write permission. Anthropic keys must permit the selected model and Messages API; identity-linked keys needing additional workspace credentials are not supported by this UI. There are no live provider keys in CI.

Publish the updated privacy/terms pages at the app's existing URLs and verify the actual public pages. Match App Store Connect privacy answers to direct provider processing; the manifest does not submit them automatically. Provider accounts still link requests to users and providers have their own retention/abuse policies. There are no Pro gates yet; later purchases/entitlements are separate work. App Store approval is not guaranteed by technical checks.

To add a provider, add explicit identity/host/credential handling, a reviewed native codec and catalog/probe tests. The Keychain, consent, model pickers, runtime documentation and scoped tool executor remain shared. Never route an unrecognized provider's key to another provider by default.

References: [OpenAI authentication/security](https://developers.openai.com/api/reference/overview), [OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling), [Claude tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools), [Claude thinking](https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting), [CPython native audit hooks](https://docs.python.org/3/c-api/sys.html#c.PySys_AddAuditHook).
