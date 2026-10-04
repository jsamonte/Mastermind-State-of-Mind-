/**
 * Provisions Firebase Authentication (Identity Platform) for the project.
 *
 * Why this exists: `signInWithCustomToken` fails with
 * `auth/configuration-not-found` until the project has an Identity Platform
 * config. The console only creates one when you enable a sign-in provider —
 * visiting the Authentication page is not enough. We need NO provider (Auth0 is
 * the IdP and we enter via custom tokens), just the config itself, which this
 * API call creates directly.
 *
 * Dependency-free on purpose: ESM resolves bare imports next to THIS file, and
 * firebase-admin lives in sidecar/node_modules.
 *
 *   node firebase/init_auth.mjs
 */
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import crypto from "node:crypto";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const projectId = "mastermind-state-of-mind";
const keyPath =
  process.env.GOOGLE_APPLICATION_CREDENTIALS ??
  path.join(root, "sidecar", "serviceAccountKey.json");

const sa = JSON.parse(await readFile(keyPath, "utf8"));

const b64url = (b) =>
  Buffer.from(b).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function token(scope) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(
    JSON.stringify({
      iss: sa.client_email,
      scope,
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    }),
  );
  const sig = b64url(
    crypto.createSign("RSA-SHA256").update(`${header}.${claims}`).sign(sa.private_key),
  );
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claims}.${sig}`,
    }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`token exchange failed: ${j.error_description ?? j.error}`);
  return j.access_token;
}

const bearer = await token("https://www.googleapis.com/auth/cloud-platform");
const call = async (method, url, body) => {
  const r = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => null);
  return { ok: r.ok, status: r.status, json: j };
};

const base = "https://identitytoolkit.googleapis.com/admin/v2";

// Already provisioned? Then there is nothing to do.
const existing = await call("GET", `${base}/projects/${projectId}/config`);
if (existing.ok) {
  console.log("Identity Platform is ALREADY provisioned for this project.");
  console.log(`  signIn: ${JSON.stringify(existing.json?.signIn ?? {})}`);
  process.exit(0);
}
console.log(`config GET -> ${existing.status}: ${existing.json?.error?.message ?? "(no config yet)"}`);

// Create it. No sign-in provider is enabled: Auth0 is the identity provider and
// the app enters Firebase through custom tokens, which need the config to exist
// but need no provider turned on.
const init = await call("POST", `${base}/projects/${projectId}/identityPlatform:initializeAuth`, {});
if (init.ok) {
  console.log("\nProvisioned Identity Platform. signInWithCustomToken should now work.");
  process.exit(0);
}

console.error(`\ninitializeAuth -> ${init.status}: ${init.json?.error?.message ?? "unknown"}`);
console.error("status:", init.json?.error?.status ?? "");
process.exit(1);
