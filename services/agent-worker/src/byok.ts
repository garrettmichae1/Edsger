import type { Env } from "./types";

// Isolated from the shared pool: no developer keys, quota, OAuth tokens or fallback.
// A personal provider key authenticates upstream. It exists only in this request's
// memory, never in cache/KV/logs. This is not an app-identity or Pro entitlement gate.
type ProviderID = "openai" | "anthropic";
type ObjectMap = Record<string, unknown>;
type WireCall = { id: string; type: "function"; function: { name: string; arguments: string } };
type WireMessage = { role: string; content: string; tool_calls?: WireCall[]; tool_call_id?: string; edsger_continuation?: string };
type Tool = { type: "function"; function: { name: string; description: string; parameters: ObjectMap } };
type CompletionBody = { model: string; messages: WireMessage[]; tools: Tool[] };
type Model = { id: string; name: string };
type Completion = { assistantText: string; toolCalls: { id: string; name: string; argumentsJSON: string }[]; continuationJSON: string; inputTokens?: number; outputTokens?: number };
export type UpstreamFetch = (url: string, init: RequestInit) => Promise<Response>;

const BODY_LIMIT = 384 * 1024;
const RESPONSE_LIMIT = 1024 * 1024;
const TIMEOUT_MS = 120_000;
const providers: Record<ProviderID, { base: string; headers: (key: string) => Record<string, string>; supports: (id: string) => boolean }> = {
  openai: {
    base: "https://api.openai.com/v1",
    headers: key => ({ Authorization: `Bearer ${key}`, "Content-Type": "application/json" }),
    // Responses text/function families; exclude audio/image/search/embedding APIs.
    supports: id => /^(gpt-(4o|4\.1|5|6)([-.]|$)|o[134]([-]|$))/.test(id) &&
      !/(audio|realtime|transcribe|tts|search|image|deep-research|chat-latest)/.test(id),
  },
  anthropic: {
    base: "https://api.anthropic.com/v1",
    headers: key => ({ "x-api-key": key, "anthropic-version": "2023-06-01", "Content-Type": "application/json" }),
    supports: id => /^claude-(sonnet|opus|haiku|3|4|5)/.test(id),
  },
};

class BYOKError extends Error {
  constructor(readonly code: string, readonly status = 400) { super(code); }
}
function record(value: unknown): ObjectMap {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new BYOKError("invalid_request");
  return value as ObjectMap;
}
function string(value: unknown, max: number, empty = false): string {
  if (typeof value !== "string" || (!empty && !value) || new TextEncoder().encode(value).length > max) throw new BYOKError("invalid_request");
  return value;
}
function array(value: unknown, max: number): unknown[] {
  if (!Array.isArray(value) || value.length > max) throw new BYOKError("invalid_request");
  return value;
}
function reply(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: {
    "Content-Type": "application/json", "Cache-Control": "no-store", "Pragma": "no-cache",
    "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
  } });
}
async function readBounded(stream: ReadableStream<Uint8Array> | null, limit: number): Promise<string> {
  if (!stream) throw new BYOKError("invalid_request");
  const reader = stream.getReader(); const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      size += value.byteLength;
      if (size > limit) { await reader.cancel(); throw new BYOKError("payload_too_large", 413); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const combined = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { combined.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(combined);
}
function parseJSON(text: string): unknown {
  try { return JSON.parse(text); } catch { throw new BYOKError("invalid_json"); }
}
function modelID(value: unknown, provider: ProviderID): string {
  const id = string(value, 160);
  if (!/^[a-zA-Z0-9._-]+$/.test(id) || !providers[provider].supports(id)) throw new BYOKError("unsupported_model");
  return id;
}
function validatedBody(value: unknown, provider: ProviderID): CompletionBody {
  const body = record(value);
  const tools = array(body.tools ?? [], 32).map(raw => {
    const tool = record(raw), fn = record(tool.function);
    const name = string(fn.name, 64);
    if (tool.type !== "function" || !/^[a-zA-Z0-9_]+$/.test(name)) throw new BYOKError("invalid_tools");
    const parameters = record(fn.parameters);
    if (parameters.type !== "object") throw new BYOKError("invalid_tools");
    return { type: "function" as const, function: { name, description: string(fn.description ?? "", 4000, true), parameters } };
  });
  if (new Set(tools.map(t => t.function.name)).size !== tools.length) throw new BYOKError("invalid_tools");
  const pending = new Set<string>(), seen = new Set<string>();
  const messages = array(body.messages, 180).map(raw => {
    const item = record(raw), role = string(item.role, 16);
    if (!["system", "user", "assistant", "tool"].includes(role)) throw new BYOKError("invalid_messages");
    if (pending.size && role !== "tool") throw new BYOKError("unpaired_tool_calls");
    const message: WireMessage = { role, content: string(item.content ?? "", 180_000, true) };
    if (item.tool_calls !== undefined) {
      if (role !== "assistant") throw new BYOKError("invalid_messages");
      message.tool_calls = array(item.tool_calls, 8).map(rawCall => {
        const call = record(rawCall), fn = record(call.function);
        const id = string(call.id, 200), name = string(fn.name, 64), args = string(fn.arguments, 65_536);
        if (seen.has(id)) throw new BYOKError("duplicate_tool_call");
        record(parseJSON(args)); seen.add(id); pending.add(id);
        return { id, type: "function" as const, function: { name, arguments: args } };
      });
    }
    if (role === "tool") {
      const id = string(item.tool_call_id, 200);
      if (!pending.delete(id)) throw new BYOKError("unpaired_tool_calls");
      message.tool_call_id = id;
    }
    if (role === "assistant" && item.edsger_continuation !== undefined) message.edsger_continuation = string(item.edsger_continuation, 180_000);
    return message;
  });
  if (pending.size || !messages.some(m => m.role === "user")) throw new BYOKError("unpaired_tool_calls");
  return { model: modelID(body.model, provider), messages, tools };
}

// Only replay native blocks for the exact provider and model. Model switches use
// normalized messages/call pairs instead of another model's opaque reasoning state.
function continuation(message: WireMessage, provider: ProviderID, model: string): ObjectMap[] | null {
  if (!message.edsger_continuation) return null;
  const saved = record(parseJSON(message.edsger_continuation));
  if (saved.provider !== provider || saved.model !== model) return null;
  const items = array(saved.items, 64).map(record);
  const allowed = provider === "openai" ? ["message", "reasoning", "function_call"] : ["text", "tool_use", "thinking", "redacted_thinking"];
  if (items.some(i => !allowed.includes(String(i.type)))) throw new BYOKError("invalid_continuation");
  // Prevent stale native tool blocks from overriding the canonical transcript.
  const calls = items.filter(i => i.type === (provider === "openai" ? "function_call" : "tool_use"));
  const expected = message.tool_calls ?? [];
  if (calls.length !== expected.length || calls.some((c, index) =>
    (provider === "openai" ? c.call_id : c.id) !== expected[index].id || c.name !== expected[index].function.name ||
    JSON.stringify(provider === "openai" ? record(parseJSON(string(c.arguments, 65_536))) : record(c.input)) !==
    JSON.stringify(record(parseJSON(expected[index].function.arguments))))) throw new BYOKError("invalid_continuation");
  return items;
}

export function openAIRequest(body: CompletionBody, forcedTool?: string): ObjectMap {
  const input: ObjectMap[] = [];
  for (const message of body.messages) {
    if (message.role === "system") continue;
    if (message.role === "tool") { input.push({ type: "function_call_output", call_id: message.tool_call_id, output: message.content }); continue; }
    const native = continuation(message, "openai", body.model);
    if (native) { input.push(...native); continue; }
    if (message.content) input.push({ role: message.role, content: message.content });
    for (const call of message.tool_calls ?? []) input.push({ type: "function_call", call_id: call.id, name: call.function.name, arguments: call.function.arguments });
  }
  return {
    model: body.model, instructions: body.messages.filter(m => m.role === "system").map(m => m.content).join("\n\n"),
    input, store: false, include: ["reasoning.encrypted_content"], max_output_tokens: 8192,
    ...(body.tools.length ? { tools: body.tools.map(t => ({ type: "function", ...t.function, strict: false })),
      parallel_tool_calls: false, tool_choice: forcedTool ? { type: "function", name: forcedTool } : "auto" } : {}),
  };
}
export function claudeRequest(body: CompletionBody, forcedTool?: string): ObjectMap {
  const messages: { role: string; content: ObjectMap[] }[] = [];
  for (const message of body.messages) {
    if (message.role === "system") continue;
    const role = message.role === "tool" ? "user" : message.role;
    const content: ObjectMap[] = [];
    if (message.role === "tool") content.push({ type: "tool_result", tool_use_id: message.tool_call_id, content: message.content });
    else {
      const native = continuation(message, "anthropic", body.model);
      if (native) content.push(...native);
      else {
        if (message.content) content.push({ type: "text", text: message.content });
        for (const call of message.tool_calls ?? []) content.push({ type: "tool_use", id: call.id, name: call.function.name, input: parseJSON(call.function.arguments) });
      }
    }
    if (!content.length) continue;
    // Consecutive results belong to one user message; results precede user text.
    if (messages.at(-1)?.role === role) messages.at(-1)!.content.push(...content);
    else messages.push({ role, content });
  }
  return { model: body.model, system: body.messages.filter(m => m.role === "system").map(m => m.content).join("\n\n"),
    messages, max_tokens: 8192,
    ...(body.tools.length ? { tools: body.tools.map(t => ({ name: t.function.name, description: t.function.description, input_schema: t.function.parameters })),
      tool_choice: forcedTool ? { type: "tool", name: forcedTool, disable_parallel_tool_use: true } : { type: "auto", disable_parallel_tool_use: true } } : {}),
  };
}

async function upstream(provider: ProviderID, key: string, path: string, method: string, payload: unknown, signal: AbortSignal, fetcher: UpstreamFetch): Promise<ObjectMap> {
  const response = await fetcher(providers[provider].base + path, {
    method, headers: providers[provider].headers(key), redirect: "error", signal,
    ...(method === "POST" ? { body: JSON.stringify(payload) } : {}),
  });
  if (!response.ok) {
    // Never echo upstream bodies: they may include credentials or private input.
    await response.body?.cancel();
    const status = response.status;
    throw new BYOKError(status === 401 ? "invalid_key" : status === 403 ? "provider_permission" :
      status === 402 ? "insufficient_credit" : status === 429 ? "provider_rate_limit" :
      status === 400 || status === 404 ? "provider_rejected" : "provider_unavailable",
      [401, 402, 403, 429].includes(status) ? status : 502);
  }
  return record(parseJSON(await readBounded(response.body, RESPONSE_LIMIT)));
}
async function complete(provider: ProviderID, key: string, body: CompletionBody, signal: AbortSignal, fetcher: UpstreamFetch, forcedTool?: string): Promise<Completion> {
  const root = await upstream(provider, key, provider === "openai" ? "/responses" : "/messages", "POST",
    provider === "openai" ? openAIRequest(body, forcedTool) : claudeRequest(body, forcedTool), signal, fetcher);
  if ((provider === "openai" && root.status !== "completed") || (provider === "anthropic" && !["end_turn", "tool_use", "stop_sequence"].includes(String(root.stop_reason)))) throw new BYOKError("incomplete_response", 502);
  const items = array(provider === "openai" ? root.output : root.content, 64).map(record);
  let text = ""; const calls: Completion["toolCalls"] = [];
  for (const item of items) {
    if (provider === "openai" && item.type === "message") {
      for (const raw of array(item.content, 64)) {
        const block = record(raw);
        if (block.type === "output_text") text += string(block.text, 180_000, true);
        if (block.type === "refusal") text += string(block.refusal, 16_000, true);
      }
    } else if (provider === "anthropic" && item.type === "text") text += string(item.text, 180_000, true);
    else if (item.type === (provider === "openai" ? "function_call" : "tool_use")) {
      const args = provider === "openai" ? string(item.arguments, 65_536) : JSON.stringify(record(item.input));
      record(parseJSON(args));
      calls.push({ id: string(provider === "openai" ? item.call_id : item.id, 200), name: string(item.name, 64), argumentsJSON: args });
    }
  }
  if (calls.length > 8 || new Set(calls.map(c => c.id)).size !== calls.length || calls.some(c => !body.tools.some(t => t.function.name === c.name))) throw new BYOKError("invalid_tool_response", 502);
  if (!text.trim() && !calls.length) throw new BYOKError("empty_response", 502);
  const usage = root.usage ? record(root.usage) : {};
  const saved = JSON.stringify({ provider, model: body.model, items });
  string(saved, 180_000);
  return { assistantText: text, toolCalls: calls, continuationJSON: saved,
    ...(typeof usage.input_tokens === "number" ? { inputTokens: usage.input_tokens } : {}),
    ...(typeof usage.output_tokens === "number" ? { outputTokens: usage.output_tokens } : {}),
  };
}
async function catalog(provider: ProviderID, key: string, signal: AbortSignal, fetcher: UpstreamFetch): Promise<Model[]> {
  const models: Model[] = []; let after: string | undefined;
  for (let page = 0; page < 10; page++) {
    const path = provider === "anthropic" ? "/models?limit=100" + (after ? "&after_id=" + encodeURIComponent(after) : "") : "/models";
    const root = await upstream(provider, key, path, "GET", undefined, signal, fetcher);
    for (const raw of array(root.data, 1000)) {
      const model = record(raw); const id = string(model.id, 160);
      if (providers[provider].supports(id)) models.push({ id, name: typeof model.display_name === "string" ? string(model.display_name, 200) : id });
    }
    if (provider !== "anthropic" || root.has_more !== true) break;
    after = string(root.last_id, 160);
    if (page === 9) throw new BYOKError("catalog_too_large", 502);
  }
  return [...new Map(models.map(m => [m.id, m])).values()].sort((a, b) => a.name.localeCompare(b.name));
}

export async function handleBYOK(request: Request, env: Env, url: URL, fetcher: UpstreamFetch = fetch): Promise<Response | null> {
  if (!url.pathname.startsWith("/v1/byok/")) return null;
  const match = /^\/v1\/byok\/(openai|anthropic)\/(models|verify|completions)$/.exec(url.pathname);
  if (!match) return reply({ error: "not_found" }, 404);
  try {
    if (url.protocol !== "https:" || url.search || request.method !== "POST") throw new BYOKError("invalid_request");
    // Deployment opt-in, not a subscription gate. Never silently run unprotected.
    if (env.BYOK_ENABLED !== "true" || !env.BYOK_RATE_LIMIT) throw new BYOKError("byok_not_configured", 503);
    const auth = request.headers.get("Authorization") ?? "";
    const key = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (key.length < 16 || key.length > 512 || !/^[\x21-\x7e]+$/.test(key)) throw new BYOKError("invalid_key", 401);
    const provider = match[1] as ProviderID, action = match[2];
    // A keyed HMAC rate identity avoids storing the raw secret or an unhashed key
    // suffix in the platform's limiter. Add an IP/WAF rule at deployment as well.
    if (!env.BYOK_RATE_SALT) throw new BYOKError("byok_not_configured", 503);
    const hmac = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.BYOK_RATE_SALT), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const hash = await crypto.subtle.sign("HMAC", hmac, new TextEncoder().encode(provider + ":" + key));
    const identity = Array.from(new Uint8Array(hash), b => b.toString(16).padStart(2, "0")).join("");
    if (!(await env.BYOK_RATE_LIMIT.limit({ key: identity })).success) throw new BYOKError("relay_rate_limit", 429);
    if (!(request.headers.get("Content-Type") ?? "").startsWith("application/json")) throw new BYOKError("invalid_request");
    const body = record(parseJSON(await readBounded(request.body, BODY_LIMIT)));
    const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
    const abort = () => controller.abort(); request.signal.addEventListener("abort", abort, { once: true });
    try {
      if (request.signal.aborted) controller.abort();
      if (action === "models") return reply({ models: await catalog(provider, key, controller.signal, fetcher) });
      if (action === "verify") {
        const model = modelID(body.model, provider), name = "edsger_connection_check";
        const probe: CompletionBody = { model,
          messages: [{ role: "user", content: "Call edsger_connection_check with value OK, then acknowledge its result in one word." }],
          tools: [{ type: "function", function: { name, description: "Non-mutating connection test. Pass value OK.", parameters: { type: "object", properties: { value: { type: "string", enum: ["OK"] } }, required: ["value"], additionalProperties: false } } }],
        };
        const first = await complete(provider, key, probe, controller.signal, fetcher, name);
        if (first.toolCalls.length !== 1 || first.toolCalls[0].name !== name || record(parseJSON(first.toolCalls[0].argumentsJSON)).value !== "OK") throw new BYOKError("tool_test_failed", 502);
        const call = first.toolCalls[0];
        probe.messages.push({ role: "assistant", content: first.assistantText, edsger_continuation: first.continuationJSON,
          tool_calls: [{ id: call.id, type: "function", function: { name, arguments: call.argumentsJSON } }] },
          { role: "tool", tool_call_id: call.id, content: "OK" });
        const final = await complete(provider, key, probe, controller.signal, fetcher);
        if (final.toolCalls.length || !final.assistantText.trim()) throw new BYOKError("tool_test_failed", 502);
        return reply({ ok: true });
      }
      return reply(await complete(provider, key, validatedBody(body, provider), controller.signal, fetcher));
    } finally { clearTimeout(timer); request.signal.removeEventListener("abort", abort); }
  } catch (error) {
    return error instanceof BYOKError ? reply({ error: error.code }, error.status) : reply({ error: "provider_unavailable" }, 502);
  }
}
