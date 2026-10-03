/**
 * auth.mjs - the Auth0 to Firebase bridge.
 *
 * Auth0 owns identity. Firestore rules need a Firebase identity. This verifies
 * an Auth0 id_token and exchanges it for a Firebase custom token whose uid is
 * the Auth0 `sub`, so `request.auth.uid` in firestore.rules is the Auth0
 * subject and nothing else has to agree on ids.
 *
 * This lives in the sidecar rather than a Cloud Function because the Firebase
 * project is on the Spark plan (Functions needs Blaze). The rule that matters -
 * never mint tokens client-side - is intact: the sidecar is not the client. It
 * already holds the Presage API key and already has to be running. The Admin
 * SDK private key never reaches the browser.
 *
 * Everything here is optional. If the deps or the config are missing, the
 * minter reports why and the rest of the app carries on unauthenticated, which
 * is what the demo needs when Auth0 details are not available yet.
 */
import { readFile } from "node:fs/promises";

/**
 * @typedef {object} Minter
 * @property {(idToken:string)=>Promise<{firebaseToken:string, uid:string, claims:object}>} mint
 * @property {string} issuer
 */

/**
 * Builds the minter, or returns `{ minter: null, reason }` explaining what is
 * missing. Never throws on misconfiguration - a missing Auth0 tenant should not
 * stop the sidecar from measuring composure.
 *
 * @returns {Promise<{minter: Minter|null, reason: string|null}>}
 */
export async function createAuthMinter({
  auth0Domain = process.env.AUTH0_DOMAIN,
  auth0Audience = process.env.AUTH0_AUDIENCE,
  serviceAccountPath = process.env.FIREBASE_SERVICE_ACCOUNT ?? "./serviceAccountKey.json",
} = {}) {
  if (!auth0Domain) {
    return { minter: null, reason: "AUTH0_DOMAIN is not set - see sidecar/.env.example" };
  }

  let jose;
  let admin;
  try {
    jose = await import("jose");
  } catch {
    return { minter: null, reason: "`jose` is not installed - run `npm install` in sidecar/" };
  }
  try {
    admin = (await import("firebase-admin")).default;
  } catch {
    return {
      minter: null,
      reason: "`firebase-admin` is not installed - run `npm install` in sidecar/",
    };
  }

  let serviceAccount;
  try {
    serviceAccount = JSON.parse(await readFile(serviceAccountPath, "utf8"));
  } catch (cause) {
    return {
      minter: null,
      reason:
        `Could not read the Firebase service account at ${serviceAccountPath} ` +
        `(${cause?.code ?? cause?.message}). Generate one in Firebase console ` +
        "-> Project settings -> Service accounts.",
    };
  }

  if (!admin.apps.length) {
    admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
  }

  // Normalise to an https issuer with a trailing slash, which is what Auth0 puts
  // in the `iss` claim. Accepting a bare domain here avoids a confusing
  // "unexpected iss" failure later.
  const issuer = auth0Domain.startsWith("http")
    ? auth0Domain.replace(/\/?$/, "/")
    : `https://${auth0Domain}/`;

  // The JWKS is cached and refreshed by jose; do not fetch per request.
  const jwks = jose.createRemoteJWKSet(new URL(`${issuer}.well-known/jwks.json`));

  return {
    reason: null,
    minter: {
      issuer,
      async mint(idToken) {
        if (typeof idToken !== "string" || !idToken) {
          throw httpError(400, "missing_token", "An Auth0 id_token is required.");
        }

        let payload;
        try {
          // Signature, issuer, audience and expiry are all checked here. Never
          // decode-without-verify: an unverified token is an attacker-supplied
          // identity, and this function's whole job is to be the gate.
          ({ payload } = await jose.jwtVerify(idToken, jwks, {
            issuer,
            ...(auth0Audience ? { audience: auth0Audience } : {}),
          }));
        } catch (cause) {
          throw httpError(401, "invalid_token", `Auth0 token rejected: ${cause?.message}`);
        }

        const uid = payload.sub;
        if (!uid) {
          throw httpError(401, "no_subject", "The Auth0 token carried no `sub` claim.");
        }

        // Pass through only claims we actually want in Firebase. Copying the
        // whole payload would risk colliding with reserved claim names, which
        // createCustomToken rejects outright.
        const claims = {
          auth0: true,
          ...(payload.email ? { email: payload.email } : {}),
          ...(payload.name ? { name: payload.name } : {}),
        };

        const firebaseToken = await admin.auth().createCustomToken(uid, claims);
        return { firebaseToken, uid, claims };
      },
    },
  };
}

function httpError(status, code, message) {
  const err = new Error(message);
  err.status = status;
  err.code = code;
  return err;
}
