/**
 * Publishes the sidecar's current public address to Firestore, so the hosted
 * app can find it without anyone pasting a URL.
 *
 * The problem this solves: Cloudflare quick tunnels are ephemeral. They die on
 * their own ("Unauthorized: Tunnel not found") and get a NEW hostname every
 * restart, so any link you hand someone goes stale. Writing the address to a
 * well-known document means the app looks it up at startup instead.
 *
 * Reads the tunnel hostname from cloudflared's log, so it stays in step with
 * whatever tunnel is actually running.
 *
 *   cd sidecar && node publish_sidecar_url.mjs --log <path-to-tunnel.log>
 *   cd sidecar && node publish_sidecar_url.mjs --url wss://host     # explicit
 *   cd sidecar && node publish_sidecar_url.mjs --clear              # offline
 */
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { cert, getApps, initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, arr) => {
    if (a.startsWith("--")) acc.push([a.slice(2), arr[i + 1]]);
    return acc;
  }, []),
);

const here = path.dirname(fileURLToPath(import.meta.url));
const keyPath =
  process.env.FIREBASE_SERVICE_ACCOUNT ?? path.join(here, "serviceAccountKey.json");

const serviceAccount = JSON.parse(await readFile(keyPath, "utf8"));
const app = getApps().length ? getApps()[0] : initializeApp({ credential: cert(serviceAccount) });
const db = getFirestore(app);
const doc = db.collection("config").doc("sidecar");

if ("clear" in args) {
  // Say "nothing is running" explicitly rather than leaving a stale address
  // that sends people at a dead tunnel.
  await doc.set({ url: null, online: false, updatedAt: FieldValue.serverTimestamp() });
  console.log("cleared: config/sidecar marked offline");
  process.exit(0);
}

let url = args.url;
if (!url) {
  const logPath = args.log ?? path.join(here, "tunnel.log");
  const log = await readFile(logPath, "utf8").catch(() => {
    throw new Error(`no tunnel log at ${logPath} — pass --url instead`);
  });
  const host = log.match(/https:\/\/([a-z0-9-]+\.trycloudflare\.com)/)?.[1];
  if (!host) throw new Error(`no trycloudflare hostname found in ${logPath}`);
  url = `wss://${host}`;
}

// Verify it actually answers before advertising it. Publishing a dead address is
// worse than publishing none: the app would stop falling back and just fail.
const httpUrl = url.replace(/^wss:/, "https:").replace(/^ws:/, "http:");
const health = await fetch(`${httpUrl}/health`, { signal: AbortSignal.timeout(20_000) })
  .then((r) => (r.ok ? r.json() : null))
  .catch(() => null);

if (!health?.ok) {
  console.error(`REFUSING to publish ${url} — /health did not answer.`);
  console.error("The tunnel is probably still registering; wait a moment and retry.");
  process.exit(1);
}

await doc.set({
  url,
  online: true,
  source: health.source ?? null,
  updatedAt: FieldValue.serverTimestamp(),
});

console.log(`published config/sidecar -> ${url}`);
console.log(`  source: ${health.source}  auth: ${health.auth}  counsel: ${health.counsel}`);
