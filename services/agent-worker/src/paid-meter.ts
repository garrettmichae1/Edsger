// Exact integer nano-US dollars. Credits use published peak rates; discounts
// lower Edsger's invoice, not the advertised allowance. This is not an invoice.
export const RATE_CARD = "flash-peak-2026-10-04-v1";
export const PRODUCT_LIMITS: Readonly<Record<string, bigint>> = Object.freeze({
  "lilc.pro.monthly": 5_000_000_000n,
  "lilc.pro.plus.monthly": 15_000_000_000n,
});
export const INPUT_RATE = 300n, CACHED_RATE = 6n, OUTPUT_RATE = 1_200n;
export const MAX_OUTPUT = 8_192, MAX_INPUT = 1_048_576;
// Reserve the entire documented context window, rather than estimating tokens.
export const RESERVATION = BigInt(MAX_INPUT) * INPUT_RATE + BigInt(MAX_OUTPUT) * OUTPUT_RATE;
function count(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw Error("invalid_usage");
  return value;
}
export function usageCost(raw: unknown): bigint {
  const u = raw as Record<string, unknown> | undefined;
  if (!u || typeof u !== "object") throw Error("invalid_usage");
  const prompt = count(u.prompt_tokens), completion = count(u.completion_tokens);
  const cached = count(u.prompt_cache_hit_tokens), uncached = count(u.prompt_cache_miss_tokens);
  // Completion tokens already include billed reasoning. Never add it twice.
  if (cached + uncached !== prompt || count(u.total_tokens) !== prompt + completion ||
      prompt > MAX_INPUT || completion > MAX_OUTPUT) throw Error("invalid_usage");
  return BigInt(uncached) * INPUT_RATE + BigInt(cached) * CACHED_RATE + BigInt(completion) * OUTPUT_RATE;
}
export interface PaidIdentity {
  originalID: string; productID: string; transactionID: string;
  purchaseDate: number; expiresDate: number;
}
export interface LedgerPeriod {
  start: number; end: number; latestPurchase: number;
  limit: string; spent: string; held: string; minute: number; requests: number;
}
export function periodFor(old: LedgerPeriod | undefined, identity: PaidIdentity, now: number): LedgerPeriod {
  const limit = PRODUCT_LIMITS[identity.productID];
  if (!limit || identity.purchaseDate > now || identity.expiresDate <= now || identity.expiresDate <= identity.purchaseDate) throw Error("membership_required");
  if (old && identity.purchaseDate < old.latestPurchase) throw Error("stale_membership");
  if (!old || identity.purchaseDate >= old.end) return { start: identity.purchaseDate, end: identity.expiresDate,
    latestPurchase: identity.purchaseDate, limit: String(limit), spent: "0", held: "0", minute: Math.floor(now / 60_000), requests: 0 };
  // Upgrades retain spending/holds. Restore, reinstall and another device do not reset it.
  return { ...old, end: Math.max(old.end, identity.expiresDate), latestPurchase: identity.purchaseDate, limit: String(limit) };
}
export function allowance(p: LedgerPeriod) {
  const remaining = BigInt(p.limit) - BigInt(p.spent) - BigInt(p.held);
  return { remainingNanoUSD: String(remaining > 0n ? remaining : 0n), limitNanoUSD: p.limit,
    renewsAt: p.end, available: remaining >= RESERVATION, rateCard: RATE_CARD };
}
