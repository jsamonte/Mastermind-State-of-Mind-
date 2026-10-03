/**
 * Reads the attempts log straight out of Firestore with the Admin credential.
 *
 * This is the end-to-end proof that the whole chain works: Auth0 login →
 * sidecar mints a Firebase custom token → the browser signs in → a write passes
 * firestore.rules. If a document is here, every link held.
 *
 * Admin reads bypass security rules, so this says the DATA arrived; it does not
 * prove the rules allowed it. A client write that rules rejected would simply
 * leave nothing here.
 *
 * This lives in sidecar/ and NOT in firebase/ for one reason: ESM resolves bare
 * imports relative to THIS FILE, not the working directory. A copy in firebase/
 * cannot see sidecar/node_modules no matter where you run it from.
 *
 *   cd sidecar && node check_record.mjs
 */
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { cert, getApps, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const root = path.dirname(fileURLToPath(import.meta.url));
const keyPath =
  process.env.FIREBASE_SERVICE_ACCOUNT ?? path.join(root, "serviceAccountKey.json");

const serviceAccount = JSON.parse(await readFile(keyPath, "utf8"));
const app = getApps().length ? getApps()[0] : initializeApp({ credential: cert(serviceAccount) });
const db = getFirestore(app);

const users = await db.collection("users").listDocuments();
if (!users.length) {
  console.log("no users/ documents yet — nothing has been written");
  process.exit(0);
}

for (const user of users) {
  console.log(`\nuser: ${user.id}`);
  const attempts = await user
    .collection("attempts")
    .orderBy("measuredAt", "desc")
    .limit(5)
    .get();

  if (attempts.empty) {
    console.log("  (no attempts)");
    continue;
  }
  for (const doc of attempts.docs) {
    const d = doc.data();
    const when = d.measuredAt?.toDate?.()?.toISOString() ?? "(pending server timestamp)";
    console.log(
      `  ${when}  verdict=${d.verdict}  composure=${d.composure ?? "null"}  ` +
        `signals=${JSON.stringify(d.signals ?? {})}`,
    );
  }
}
