# Edsger funded mobile agent

The worker implements the non-BYOK Dijkstra Super Fast 1.0 connection. Personal OpenAI/Claude requests still go directly from the iPhone to their provider. `/v1/byok/*` and every old free-pool/unlimited-subscription route return 410. The paid routes are disabled by default.

## Membership contract

| Apple product | US monthly price configured in App Store Connect | Monthly allowance |
| --- | ---: | ---: |
| `lilc.pro.monthly` | $10.00 | $5.00 |
| `lilc.pro.plus.monthly` | $25.00 | $15.00 |

Create both as monthly auto-renewable subscriptions in ONE group. Pro Plus is level 1; Pro is level 2. Disable Family Sharing. StoreKit displays Apple's localized purchase price. The local `.storekit` file is a preview, never server authentication. Legacy `lilc.agent.monthly` does not grant a funded allowance.

Allowances are **AI credits at the versioned published DeepSeek Flash peak tariff**, not cash, token packs or a representation of the actual upstream invoice. Credits use reported usage, including caching and all billed output/reasoning. Off-peak discounts reduce Edsger's expense; they do not change this credit tariff. No hard-coded message/task counts or unlimited plans exist. Subscription billing periods, not calendar months, govern renewal. Restore/reinstall/multiple devices share one original-transaction ledger. An upgrade raises the period's total ceiling to $15 and retains prior spending/reservations; it does not add a second $15 grant. No rollover.

`paid-meter.ts` uses **integer nano-USD** throughout. A token costs 300 nano-USD for uncached input, 6 for cached input, and 1,200 for output. $5 is exactly 5,000,000,000 nano-USD; $15 is exactly 15,000,000,000. Invalid/missing usage is never silently treated as free. These rates were checked against https://api-docs.deepseek.com/quick_start/pricing/ on 2026-10-04. Recheck pricing before enabling and whenever the upstream tariff changes. If DeepSeek increases its rate, disable the paid agent before updating the versioned tariff; a fixed token ledger cannot guarantee a future provider invoice.

Before a provider call, a storage transaction reserves the cost of the ENTIRE documented 1,048,576-token input context plus 8,192 output tokens: **$0.3244032** at peak rates. This conservative guard avoids pretending byte estimates are an exact tokenizer. A successful call settles its actual reported usage once, releasing unused capacity. The remaining balance must cover this guard to start another request: up to 32.44032 cents can remain unusable at period end. UI says the remaining allowance cannot cover another request; it does not falsely report a zero balance. A smaller guard requires a verified exact tokenizer/context bound, not an optimistic estimate.

Two requests cannot race the same balance. Duplicate request IDs never initiate a second paid call or replay a tool response. Non-billable explicit 4xx/429 rejections release reservations. A disconnect, 5xx, missing usage or worker interruption is financially ambiguous: retain the hold for reconciliation rather than retrying or resetting spending. Do not mistake a retained hold for settled actual usage. Request records retain only an ID, period, financial amount and settlement state; prompts/code/results are never written to ledger storage.

## Security and endpoints

- `GET /v1/mobile-agent/allowance`
- `POST /v1/mobile-agent/completions`, bounded to 384 KiB
- Header `X-Apple-Transaction-JWS`: actual signed StoreKit transaction; treat as a bearer credential.
- Completion also requires `X-Edsger-AI-Consent: v1` and a fresh UUID in `X-Edsger-Request-ID`.

Apple's official `SignedDataVerifier` verifies certificate chains against configured Apple root certificates with current validity and online revocation checking. Every request rechecks current subscription state with Apple's authenticated Server API. Self-signed `x5c`, device IDs, GitHub tokens and debug flags never grant paid access. Production cannot accept Xcode StoreKit or sandbox receipts. Sandbox testing uses a separately deployed worker/namespace and key configuration. Keep server credentials, receipts and provider diagnostics out of logs.

Only `deepseek-flash` is callable, with non-thinking mode and 8,192 output tokens maximum. Client-supplied provider/model/pricing/output overrides are ignored. Redirects are rejected. Outputs and tool lists are bounded; incomplete output is rejected. The iPhone validates the ENTIRE tool batch against its shared tool registry before executing anything, then enforces existing read-before-edit, workspace, runtime, safeguard and checkpoint policies. Runtime guides remain on-demand once per topic/task. Ordinary Chat has the same document/math capabilities as BYOK Chat; project mutations belong to Agent IDE. No model gains arbitrary app/OS permissions.

Chat can retry a read-only turn locally on allowance/provider rate limits, with cloud text buffered until completion. IDE stops a partially executed task and preserves edits/checkpoints; the next request runs locally. Never restart a mutated tool loop automatically under another model. Explicit BYOK choices retain priority and never consume these allowances. The funded service never receives personal provider keys.

## Deployment: not done in this environment

1. Set the two products, prices, levels and group in App Store Connect. Generate an In-App Purchase App Store Server API key for the correct app. Obtain Apple's current root certificates from Apple's certificate authority page; encode DER certificate bytes as a JSON array of base64 strings. Verify their origin/fingerprints. Never trust certificates supplied by a client.
2. Keep `PAID_AGENT_ENABLED = "false"`. Confirm the actual bundle ID (`app.lilc` in this project), numeric App Store app ID and `APPLE_ENVIRONMENT = "Production"`.
3. Configure server-only secrets using interactive `npx wrangler secret put NAME`: `DEEPSEEK_API_KEY`, `APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` (the .p8 contents), `APPLE_APP_ID`, `APPLE_ROOT_CERTIFICATES`. Do not put values in source, terminal command arguments/history, app configuration or documentation.
4. Run `npm ci`, `npm run typecheck`, `npm test` and `npm run check:runtime`. Deploy the disabled worker with `npx wrangler deploy`. Create the SQLite Durable Object namespace using the checked-in migration. Map the domain to `api.lilc.app`. Use a SEPARATE sandbox worker/ledger and `APPLE_ENVIRONMENT = "Sandbox"` for acceptance testing.
5. Verify real Apple sandbox purchases, renewals, upgrade/downgrade, restore on a second device, revocation/refund, concurrent Chat/IDE, rate limits, interrupted requests and native TLS redirect rejection. Verify online certificate checks and Apple's Server API in the actual Cloudflare runtime. Local fixtures/dry-run bundles do not establish these external services work.
6. Configure provider-account spending limits/alerts, Cloudflare rate limiting before receipt verification, and aggregate budget alerts. Define a restricted operator process for retained-hold reconciliation, a billing-record retention/deletion policy, and any account/receipt misuse controls before launch. Keep observability body/credential logging disabled. No operational dashboard/reconciliation endpoint is exposed in this patch.
7. Update and publish the existing privacy/terms pages and App Store privacy answers for subscription identifiers, purchase history, usage records and DeepSeek processing/retention. The manifest and consent text do not publish these pages or submit App Store answers. This code does not guarantee App Store acceptance.
8. After acceptance, set the worker flag true and flip `MobileAgentConfiguration.isEnabled` in an app build. Update the explicit prelaunch test that checks the disabled flag. Never sell memberships while the service is unavailable. A signing-only/compile-only check is insufficient to flip these gates.

Both $10/$5 and $25/$15 allocations are before overhead. At an eligible 15% Apple commission, $3.50 and $6.25 remain respectively before hosting, support and taxes. At 30%, $2 and $2.50 remain. Discounts may improve this; do not promise profits from those margins.
