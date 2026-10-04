/**
 * Reports what is needed to host the sidecar on Cloud Run: billing, the APIs,
 * and whether the service account can act.
 *
 * Read-only. Dependency-free so it runs from anywhere in the repo.
 */
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import crypto from "node:crypto";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const projectId = "mastermind-state-of-mind";
const sa = JSON.parse(
  await readFile(
    process.env.GOOGLE_APPLICATION_CREDENTIALS ??
      path.join(root, "sidecar", "serviceAccountKey.json"),
    "utf8",
  ),
);

const b64url = (b) =>
  Buffer.from(b).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

const now = Math.floor(Date.now() / 1000);
const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
const claims = b64url(
  JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/cloud-platform",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }),
);
const sig = b64url(
  crypto.createSign("RSA-SHA256").update(`${header}.${claims}`).sign(sa.private_key),
);
const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion: `${header}.${claims}.${sig}`,
  }),
}).then((r) => r.json());

if (!tokenRes.access_token) {
  console.error("could not mint a token:", tokenRes.error_description ?? tokenRes.error);
  process.exit(1);
}
const bearer = tokenRes.access_token;

const get = async (url) => {
  const r = await fetch(url, { headers: { Authorization: `Bearer ${bearer}` } });
  return { status: r.status, json: await r.json().catch(() => null) };
};

console.log(`project: ${projectId}`);
console.log(`acting as: ${sa.client_email}\n`);

// 1. Billing — Cloud Run cannot be used without it.
const billing = await get(
  `https://cloudbilling.googleapis.com/v1/projects/${projectId}/billingInfo`,
);
if (billing.status === 200) {
  const enabled = billing.json?.billingEnabled;
  console.log(`billing:        ${enabled ? "ENABLED" : "NOT enabled (Spark)"}`);
  if (billing.json?.billingAccountName) {
    console.log(`                account ${billing.json.billingAccountName}`);
  }
} else {
  console.log(
    `billing:        could not read (${billing.status}: ${billing.json?.error?.message ?? ""})`,
  );
}

// 2. The APIs a Cloud Run deploy needs.
for (const api of ["run.googleapis.com", "cloudbuild.googleapis.com", "artifactregistry.googleapis.com"]) {
  const r = await get(
    `https://serviceusage.googleapis.com/v1/projects/${projectId}/services/${api}`,
  );
  const state = r.status === 200 ? r.json?.state : `unreadable (${r.status})`;
  console.log(`${api.padEnd(30)} ${state}`);
}

// 3. Can this service account actually deploy?
const perms = await fetch(
  `https://cloudresourcemanager.googleapis.com/v1/projects/${projectId}:testIamPermissions`,
  {
    method: "POST",
    headers: { Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      permissions: ["run.services.create", "run.services.update", "cloudbuild.builds.create"],
    }),
  },
).then((r) => r.json().catch(() => null));

console.log(`\ndeploy permissions held: ${JSON.stringify(perms?.permissions ?? [])}`);
