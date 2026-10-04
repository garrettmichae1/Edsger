import { paidRoute } from "./paid-service";
import { json } from "./openai";
export { MobileAgentLedger } from "./paid-ledger";

export default {
  async fetch(request: Request, env: import("./types").Env): Promise<Response> {
    const path = new URL(request.url).pathname;
    // No retired route may bypass the paid ledger or accept personal keys.
    if (path.startsWith("/v1/byok/")) return json({ error: "byok_direct_only" }, 410);
    if (path === "/health") return json({ ok: true, service: "edsger-mobile-agent" });
    if (path.startsWith("/v1/mobile-agent/")) return paidRoute(request, env);
    return json({ error: "route_retired" }, 410);
  },
} satisfies ExportedHandler<import("./types").Env>;
