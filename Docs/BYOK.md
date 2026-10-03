# OpenAI and Claude BYOK (iPhone)

Settings → BYOK accepts personal OpenAI and Anthropic API keys, loads each account’s model catalog, and verifies a model with a non-mutating native tool round trip before storing the key. Chat and Agent IDE have model selectors. No Pro gate, purchase link, or provider-credit sales are introduced. Ordinary Chat retains documents and bounded on-device math; project mutations remain in Agent IDE.

## Architecture and capability boundary

`BYOKProvider`, `BYOKStore` and the relay’s provider registry separate provider identity, account credentials, model catalog and user selections. Credentials use device-only, unlocked iOS Keychain entries. UserDefaults stores only model IDs, catalog labels, consent and selections. Key replacement preserves a working key if verification fails. Removing a key retains selected provider IDs, so errors never silently use another account or the shared allowance.

The fixed HTTPS relay URL is `https://api.lilc.app/v1/byok`. The relay sends personal keys only to fixed OpenAI/Anthropic hosts. It uses OpenAI Responses with `store:false` and encrypted reasoning continuation, and Anthropic Messages with native tool_use/tool_result blocks. Native state is reused only with the exact same provider and model. No developer key, GitHub token, StoreKit credential, shared quota or user-specified upstream URL enters this route.

Agent tools run locally through the existing project workspace and runtimes: list/read/create/edit/select files, folders, code execution, output, stopping, guarded deletion and bounded SymPy calculations. Cloud models receive tool definitions and scoped results; they do not directly write files or gain arbitrary Python, shell, package installation, internet browsing, computer use or provider-hosted tools. Existing safeguards, read-before-edit checks, checkpoints, cancellation and bounded steps remain. Chat has no project mutation tools. A cloud response is delivered as a completed result; incremental text streaming is not included in this first integration.

All tool arguments in a batch are validated before any operation. Tool call/result IDs are preserved. Interrupted or legacy orphan histories become historical text, without replaying operations. Requests capture a model and credential for their duration. Configuration is locked during tasks/tests, but sharing consent can be withdrawn; every subsequent cloud request checks it. Cancellation cannot retract a provider request already received or guarantee that its usage was not billed.

## Deployment required before cloud use

The checked-in relay is **disabled by default**. This is deployment protection, not a Pro gate. A personal API key authenticates upstream, but is not Edsger app-identity authentication. Future subscription entitlement and App Attest integration are separate work.

1. Provision the existing Worker on the fixed app-controlled HTTPS hostname, or change the build-time URL to an app-controlled HTTPS relay before shipping. Do not give users an editable gateway URL.
2. Assign `BYOK_RATE_LIMIT` a Cloudflare account-unique namespace; the sample `1003` must be checked against the account. The configuration uses the rate-limit binding syntax compatible with the repo’s Wrangler 3 version. Rate limits apply per Cloudflare location and are not a global spending budget.
3. Generate a strong random secret and use `npx wrangler secret put BYOK_RATE_SALT` to store it directly with Cloudflare. Never put secrets in git, preferences, logs, documentation or chat. No OpenAI/Claude developer secret is needed for BYOK.
4. Add an IP/WAF abuse rule, request-size protection and operator access controls. Keep Workers application logging, observability, Logpush body/header capture and error-report payload capture disabled for BYOK. Audit the account’s actual logging configuration: source configuration alone cannot guarantee infrastructure settings.
5. Set `BYOK_ENABLED = "true"` only after the hostname, binding, secret and privacy controls are configured. Deploy using the operator’s existing Cloudflare process. The iPhone Settings page otherwise shows a safe service-unavailable error.
6. Publish the updated `privacy.html` and `terms.html` at the URLs already linked by the app. Check those real public URLs. No hosting deployment is included in this change.
7. Test both providers using separate owner-controlled test keys entered in the app. Restricted OpenAI keys need models-read and Responses-write permissions. Anthropic keys must permit the chosen model and Messages API. Verify create/read/edit/run/output, project boundaries, guards, restore, Stop, switching, revoked keys, insufficient credit and provider rate limits on a physical iPhone. Verify access before shipping; catalogs and a tool probe are not a guarantee of every model’s task quality.

## Release and App Store review

The Settings disclosure names the selected AI provider and relay/Cloudflare, lists shared data and requests explicit per-provider consent before network tests or usage. Consent can be withdrawn and saved keys removed. Provider API billing is clearly separate from app purchases and consumer subscriptions. Review App Privacy answers for user content and identifiers transmitted to the relay/providers, provider terms, age requirements, and reviewer instructions against the production configuration. Do not label BYOK as entirely offline or promise App Store approval. There are no Pro gates yet; add any future paid unlock with an Apple-compliant purchase design and a separate policy review.

## Validation

- `npm ci --ignore-scripts && npm run typecheck && npm test` in `services/agent-worker`.
- `npx wrangler deploy --dry-run` validates packaging and bindings without deploying.
- `bash scripts/test-byok.sh` on macOS compiles the actual Keychain, provider transport, store and domain under Swift 6 and runs isolated state/history/tool validation tests without provider keys.
- The `BYOK checks` workflow runs those checks, existing math/model regressions and an unsigned device build of the application and BYOK unit-test target. Full simulator/physical-device agent tests and live API tests are additional release checks; an unsigned build does not cover them.

To add another provider, add its enum identity, fixed-host credential header/model filter and native request/response codec, plus catalog/probe fixtures. The Keychain, settings, consent, selection and local tool executor remain shared. Provider tools and supported model families must be explicitly reviewed rather than assuming OpenAI-compatible JSON supplies full agent support.
