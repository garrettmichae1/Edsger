import type { Env } from "./types";
import { allowance, periodFor, RESERVATION, usageCost, type PaidIdentity, type LedgerPeriod } from "./paid-meter";
import { modelRequest, modelCompletion } from "./paid-model";
import { boundedJSON, paidJSON } from "./paid-service";

interface Entry { period: string; amount: string; status: "pending" | "settled" | "uncertain" | "rejected" }
// One strongly consistent object per VERIFIED original Apple subscription,
// shared by Chat, IDE and all devices. No prompts or generated code are persisted.
export class MobileAgentLedger {
  constructor(private state: DurableObjectState, private env: Env) {}
  async fetch(request: Request): Promise<Response> {
    if (this.env.PAID_AGENT_ENABLED !== "true" || !this.env.DEEPSEEK_API_KEY) return paidJSON({ error: "service_unavailable" }, 503);
    const { identity, requestID, body } = await request.json() as { identity: PaidIdentity; requestID: string; body: unknown };
    const isCompletion = new URL(request.url).pathname === "/completions";
    let upstream: ReturnType<typeof modelRequest> | undefined;
    try { if (isCompletion) upstream = modelRequest(body); }
    catch { return paidJSON({ error: "invalid_request" }, 400); }
    let periodKey = "";
    let snapshot: ReturnType<typeof allowance> | undefined;
    try {
      await this.state.storage.transaction(async tx => {
        const now = Date.now();
        const old = await tx.get<LedgerPeriod>("current");
        const period = periodFor(old, identity, now);
        periodKey = `period:${period.start}`;
        snapshot = allowance(period);
        if (isCompletion) {
          if (await tx.get(`request:${requestID}`)) throw Error("duplicate_request");
          if ((await tx.get<number>("activeUntil") ?? 0) > now) throw Error("busy");
          if (!snapshot.available) throw Error("allowance_exhausted");
          const minute = Math.floor(now / 60_000);
          if (period.minute !== minute) { period.minute = minute; period.requests = 0; }
          if (period.requests >= 30) throw Error("rate_limited");
          period.requests++;
          period.held = String(BigInt(period.held) + RESERVATION);
          await tx.put(`request:${requestID}`, { period: periodKey, amount: String(RESERVATION), status: "pending" } satisfies Entry);
          await tx.put("activeUntil", now + 120_000);
        }
        await tx.put(periodKey, period);
        await tx.put("current", period);
      });
    } catch (error) {
      const code = error instanceof Error ? error.message : "service_unavailable";
      const status = code === "allowance_exhausted" || code === "rate_limited" ? 429 : code === "busy" || code === "duplicate_request" ? 409 : 403;
      return paidJSON({ error: code, ...(snapshot ? { allowance: snapshot } : {}) }, status);
    }
    if (!isCompletion) return paidJSON({ allowance: snapshot });
    try {
      const response = await fetch("https://api.deepseek.com/chat/completions", {
        method: "POST", headers: { Authorization: `Bearer ${this.env.DEEPSEEK_API_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify(upstream), redirect: "manual", signal: AbortSignal.timeout(90_000),
      });
      if (!response.ok) {
        // Only explicit non-billable rejection releases the hold. Ambiguous 5xx,
        // disconnect or missing usage retains it for operator reconciliation.
        const knownRejection = (response.status >= 300 && response.status < 400) || [400, 401, 403, 404, 422, 429].includes(response.status);
        await this.settle(requestID, null, knownRejection ? "rejected" : "uncertain");
        await response.body?.cancel();
        return paidJSON({ error: response.status === 429 ? "rate_limited" : "service_unavailable" }, response.status === 429 ? 429 : 503);
      }
      const root = await boundedJSON(response, 1024 * 1024) as { usage?: unknown };
      const cost = usageCost(root.usage);
      if (cost > RESERVATION) throw Error("invalid_usage");
      // Settle actual reported tokens even when the response's tools are invalid.
      const current = await this.settle(requestID, cost, "settled");
      const completion = modelCompletion(root, upstream!);
      return paidJSON({ completion, allowance: current });
    } catch {
      await this.settle(requestID, null, "uncertain");
      return paidJSON({ error: "service_unavailable" }, 503);
    }
  }
  private async settle(requestID: string, cost: bigint | null, status: Entry["status"]) {
    let result: ReturnType<typeof allowance> | undefined;
    await this.state.storage.transaction(async tx => {
      const key = `request:${requestID}`;
      const entry = await tx.get<Entry>(key);
      if (!entry || entry.status !== "pending") return; // Exactly-once settlement.
      const period = await tx.get<LedgerPeriod>(entry.period);
      if (!period) throw Error("ledger_unavailable");
      if (status !== "uncertain") {
        period.held = String(BigInt(period.held) - BigInt(entry.amount));
        period.spent = String(BigInt(period.spent) + (cost ?? 0n));
      }
      entry.status = status;
      entry.amount = String(cost ?? BigInt(entry.amount));
      await tx.put(key, entry);
      await tx.put(entry.period, period);
      const current = await tx.get<LedgerPeriod>("current");
      if (current?.start === period.start) await tx.put("current", period);
      await tx.delete("activeUntil");
      result = allowance(current && current.start !== period.start ? current : period);
    });
    return result;
  }
}
