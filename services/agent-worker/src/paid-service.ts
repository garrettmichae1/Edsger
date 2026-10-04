import { paidIdentity } from "./paid-auth";
import { json } from "./openai";
import type { Env } from "./types";

export function paidJSON(body: unknown, status = 200): Response {
  const response = json(body, status);
  response.headers.set("Cache-Control", "no-store");
  response.headers.set("X-Content-Type-Options", "nosniff");
  return response;
}
export async function boundedJSON(request: Request | Response, limit: number): Promise<unknown> {
  const reader = request.body?.getReader();
  if (!reader) throw Error("invalid_request");
  const chunks: Uint8Array[] = [];
  let count = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      count += value.byteLength;
      if (count > limit) throw Error("payload_too_large");
      chunks.push(value);
    }
  } catch (error) { await reader.cancel(); throw error; }
  const bytes = new Uint8Array(count);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
}
export async function paidRoute(request: Request, env: Env): Promise<Response> {
  const path = new URL(request.url).pathname;
  const action = request.method === "GET" && path === "/v1/mobile-agent/allowance" ? "allowance" :
    request.method === "POST" && path === "/v1/mobile-agent/completions" ? "completions" : null;
  if (!action) return paidJSON({ error: "not_found" }, 404);
  // Fail closed BEFORE reading prompts, receipts or invoking any provider.
  if (env.PAID_AGENT_ENABLED !== "true" || !env.DEEPSEEK_API_KEY || !env.MOBILE_AGENT_LEDGER) return paidJSON({ error: "service_unavailable" }, 503);
  try {
    const identity = await paidIdentity(request, env);
    if (action === "completions" && request.headers.get("X-Edsger-AI-Consent") !== "v1") return paidJSON({ error: "consent_required" }, 403);
    const requestID = request.headers.get("X-Edsger-Request-ID") ?? "";
    if (action === "completions" && !/^[a-f0-9-]{36}$/i.test(requestID)) return paidJSON({ error: "invalid_request" }, 400);
    const body = action === "completions" ? await boundedJSON(request, 384 * 1024) : null;
    const id = env.MOBILE_AGENT_LEDGER.idFromName(identity.originalID);
    return env.MOBILE_AGENT_LEDGER.get(id).fetch(new Request(`https://ledger/${action}`, {
      method: "POST", body: JSON.stringify({ identity, requestID, body }),
    }));
  } catch (error) {
    const code = error instanceof Error ? error.message : "service_unavailable";
    if (code === "membership_required") return paidJSON({ error: code }, 403);
    if (code === "payload_too_large") return paidJSON({ error: code }, 413);
    // No raw Apple/provider errors, receipt data, request bodies or keys in output/logs.
    return paidJSON({ error: "service_unavailable" }, 503);
  }
}
