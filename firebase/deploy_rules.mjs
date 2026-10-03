/**
 * Deploys firestore.rules using the Admin service account, by calling the
 * Firebase Rules REST API directly.
 *
 * Why not `firebase deploy --only firestore:rules`: that CLI first asks
 * serviceusage.googleapis.com whether the Firestore API is enabled, and the
 * firebase-adminsdk service account lacks `serviceusage.services.get`. The
 * check fails with 403 before it ever tries to write a rule. The API is
 * obviously enabled — the database exists — so the precheck is the only
 * blocker, and talking to the Rules API skips it.
 *
 * Usage:
 *   node firebase/deploy_rules.mjs [--project <id>] [--rules <path>]
 */
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import crypto from "node:crypto";
import path from "node:path";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, arr) => {
    if (a.startsWith("--")) acc.push([a.slice(2), arr[i + 1]]);
    return acc;
  }, []),
);

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const projectId = args.project ?? "mastermind-state-of-mind";
const rulesPath = args.rules ?? path.join(root, "firebase", "firestore.rules");
const keyPath =
  process.env.GOOGLE_APPLICATION_CREDENTIALS ??
  path.join(root, "sidecar", "serviceAccountKey.json");

const serviceAccount = JSON.parse(await readFile(keyPath, "utf8"));
const source = await readFile(rulesPath, "utf8");

/**
 * Mints a Google OAuth access token from the service account with the JWT-bearer
 * flow, using only node:crypto.
 *
 * Deliberately dependency-free: firebase-admin lives in sidecar/node_modules,
 * and ESM resolves bare imports relative to THIS file, not the working
 * directory — so importing it from here fails no matter where you run it from.
 */
async function getAccessToken(sa, scope) {
  const b64url = (buf) =>
    Buffer.from(buf).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

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
  const signature = b64url(
    crypto.createSign("RSA-SHA256").update(`${header}.${claims}`).sign(sa.private_key),
  );

  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claims}.${signature}`,
    }),
  });
  const json = await response.json();
  if (!response.ok) {
    throw new Error(`token exchange failed: ${json.error_description ?? json.error}`);
  }
  return json.access_token;
}

const token = await getAccessToken(
  serviceAccount,
  "https://www.googleapis.com/auth/cloud-platform",
);

const api = async (method, url, body) => {
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await response.json().catch(() => null);
  if (!response.ok) {
    const err = new Error(json?.error?.message ?? `HTTP ${response.status}`);
    err.status = response.status;
    err.body = json;
    throw err;
  }
  return json;
};

const base = `https://firebaserules.googleapis.com/v1/projects/${projectId}`;

console.log(`project: ${projectId}`);
console.log(`rules:   ${rulesPath} (${source.length} bytes)`);

// 1. Upload the ruleset. This also compiles it — a syntax error fails here,
//    before anything is released, so a bad ruleset can never go live.
const ruleset = await api("POST", `${base}/rulesets`, {
  source: { files: [{ name: "firestore.rules", content: source }] },
});
console.log(`ruleset: ${ruleset.name}`);

// 2. Point the live release at it. The release already exists (the console
//    created one with the locked default), so PATCH; fall back to POST if not.
const releaseName = `projects/${projectId}/releases/cloud.firestore`;
try {
  await api("PATCH", `https://firebaserules.googleapis.com/v1/${releaseName}`, {
    release: { name: releaseName, rulesetName: ruleset.name },
  });
  console.log("release: updated cloud.firestore");
} catch (err) {
  if (err.status !== 404) throw err;
  await api("POST", `${base}/releases`, {
    name: releaseName,
    rulesetName: ruleset.name,
  });
  console.log("release: created cloud.firestore");
}

console.log("\nrules are live");

// --- verification -----------------------------------------------------------
// Read the LIVE release back and compare it to the file on disk. A deploy that
// reports success but released the wrong ruleset is worse than no deploy, so
// this never trusts the write's own response.
const live = await api("GET", `https://firebaserules.googleapis.com/v1/${releaseName}`);
const liveRuleset = await api("GET", `https://firebaserules.googleapis.com/v1/${live.rulesetName}`);
const liveSource = liveRuleset.source.files.map((f) => f.content).join("");
console.log(`\nlive release -> ${live.rulesetName}`);
console.log(`matches disk  -> ${liveSource === source ? "YES" : "NO — MISMATCH"}`);
if (liveSource !== source) process.exitCode = 1;
