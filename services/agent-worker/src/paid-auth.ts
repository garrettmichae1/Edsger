import { Buffer } from "node:buffer";
import { importPKCS8, SignJWT } from "jose";
import type { Env } from "./types";
import { PRODUCT_LIMITS, type PaidIdentity } from "./paid-meter";

export async function paidIdentity(request: Request, env: Env): Promise<PaidIdentity> {
  if (!env.APPLE_ROOT_CERTIFICATES || !env.APPLE_ISSUER_ID || !env.APPLE_KEY_ID ||
      !env.APPLE_PRIVATE_KEY || !env.APPLE_APP_ID || !env.APPLE_BUNDLE_ID) throw Error("service_unavailable");
  const jws = request.headers.get("X-Apple-Transaction-JWS") ?? "";
  if (jws.length < 100 || jws.length > 24_000 || jws.split(".").length !== 3) throw Error("membership_required");
  // The SDK's crypto dependency initializes randomness. Workers forbids this
  // at module/global scope: lazy-load inside the authenticated request handler.
  const { SignedDataVerifier, Environment } = await import("@apple/app-store-server-library");
  // Sandbox is a separately deployed worker. No Xcode StoreKit or debug bypass.
  const environment = env.APPLE_ENVIRONMENT === "Sandbox" ? Environment.SANDBOX : Environment.PRODUCTION;
  const roots = JSON.parse(env.APPLE_ROOT_CERTIFICATES) as string[];
  if (!Array.isArray(roots) || !roots.length || roots.some(x => typeof x !== "string")) throw Error("service_unavailable");
  const verifier = new SignedDataVerifier(roots.map(x => Buffer.from(x, "base64")), true,
    environment, env.APPLE_BUNDLE_ID, Number(env.APPLE_APP_ID));
  const proof = await verifier.verifyAndDecodeTransaction(jws);
  if (!proof.originalTransactionId || !proof.transactionId || !proof.productId || !PRODUCT_LIMITS[proof.productId] ||
      proof.revocationDate || !proof.expiresDate || proof.expiresDate <= Date.now() || !/^\d{1,40}$/.test(proof.originalTransactionId)) throw Error("membership_required");
  const key = await importPKCS8(env.APPLE_PRIVATE_KEY, "ES256");
  const token = await new SignJWT({ bid: env.APPLE_BUNDLE_ID }).setProtectedHeader({ alg: "ES256", kid: env.APPLE_KEY_ID, typ: "JWT" })
    .setIssuer(env.APPLE_ISSUER_ID).setAudience("appstoreconnect-v1").setIssuedAt().setExpirationTime("5m").sign(key);
  // Live Apple status closes stale signed-receipt refunds/revocations/plan changes.
  const host = environment === Environment.SANDBOX ? "api.storekit-sandbox.itunes.apple.com" : "api.storekit.itunes.apple.com";
  const response = await fetch(`https://${host}/inApps/v1/subscriptions/${proof.originalTransactionId}`, {
    headers: { Authorization: `Bearer ${token}` }, redirect: "error", signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw Error("service_unavailable");
  const body = await response.json() as { data?: { lastTransactions?: { status?: number; signedTransactionInfo?: string }[] }[] };
  let latest: PaidIdentity | undefined;
  for (const group of body.data ?? []) for (const entry of group.lastTransactions ?? []) {
    if (entry.status !== 1 || !entry.signedTransactionInfo) continue;
    const t = await verifier.verifyAndDecodeTransaction(entry.signedTransactionInfo);
    if (t.originalTransactionId !== proof.originalTransactionId || !t.productId || !PRODUCT_LIMITS[t.productId] ||
        !t.transactionId || t.revocationDate || !t.purchaseDate || !t.expiresDate || t.expiresDate <= Date.now() || t.isUpgraded) continue;
    if (!latest || t.purchaseDate > latest.purchaseDate) latest = { originalID: t.originalTransactionId,
      productID: t.productId, transactionID: t.transactionId, purchaseDate: t.purchaseDate, expiresDate: t.expiresDate };
  }
  if (!latest) throw Error("membership_required");
  return latest;
}
