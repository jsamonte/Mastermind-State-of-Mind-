# Hosting the sidecar on Cloud Run

This makes the measurement service survive your laptop closing: no tunnel to
expire, no address to republish, automatic restart if it crashes.

It does **not** make measurements work for distant visitors — that is a
bandwidth problem (raw frames are ~55 Mbps upload), not a hosting one. See the
end of this file.

## What only you can do

Checked programmatically on 2026-10-04 against the project:

```
billing:                        NOT enabled (Cloud Billing API is off entirely)
run.googleapis.com              unreadable (403)
deploy permissions held:        []        <- the firebase-adminsdk account has none
```

So two things need your Google account, and no automation can substitute:

1. **Enable Blaze.** Firebase console → ⚙ → Usage and billing → Details &
   settings → Modify plan → Blaze. This attaches a card. Cloud Run has a free
   allowance but still requires a billing account to exist.
2. **Deploy as yourself.** You are Owner on the project; the service account is
   not, and should not be made one just for this.

## Deploying, without installing anything

Use **Cloud Shell** — a browser terminal with `gcloud`, Docker and your
credentials already loaded. Open the Firebase console and click the Cloud Shell
icon (`>_`, top right), or go to <https://shell.cloud.google.com>.

```bash
git clone https://github.com/jsamonte/Mastermind-State-of-Mind-.git
cd Mastermind-State-of-Mind-/sidecar

gcloud config set project mastermind-state-of-mind
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com

gcloud run deploy mastermind-sidecar \
  --source . \
  --region us-central1 \
  --allow-unauthenticated \
  --memory 2Gi \
  --cpu 2 \
  --timeout 3600 \
  --min-instances 1 \
  --set-env-vars "SIDECAR_HOST=0.0.0.0,EXTRA_ORIGINS=https://mastermind-state-of-mind.web.app" \
  --set-env-vars "PRESAGE_API_KEY=...,GEMINI_API_KEY=...,AUTH0_DOMAIN=jared-v-samonte.us.auth0.com"
```

`--source .` builds the Dockerfile with Cloud Build, so you never need Docker
locally.

**Make sure the push is current first.** The Dockerfile and the deployable
server changes must be committed and pushed, or Cloud Shell clones a version
that cannot run.

### Why those flags

| Flag | Reason |
| --- | --- |
| `--memory 2Gi` | The SmartSpectra runtime loads ML models. 512Mi will OOM. |
| `--cpu 2` | Real-time video processing; one vCPU falls behind the 25fps floor. |
| `--timeout 3600` | A casing holds a WebSocket open for a minute, plus idle time. |
| `--min-instances 1` | A cold start mid-demo looks like a crash. This costs money while idle — drop it to 0 if you would rather save it. |
| `EXTRA_ORIGINS` | The ONLY thing stopping an arbitrary page opening a socket and spending your Presage credits. Not optional. |
| `SIDECAR_HOST=0.0.0.0` | The server refuses to listen off-loopback without this, by design. |

Secrets go in as env vars, never into the image — `.dockerignore` excludes
`.env` and `serviceAccountKey.json` for exactly that reason.

### Firestore persistence on Cloud Run

`AUTH0_DOMAIN` alone gets you token verification. For the Firebase custom-token
mint you also need the service account inside the container. The clean way is
Secret Manager:

```bash
gcloud secrets create mastermind-sa --data-file=serviceAccountKey.json
gcloud run services update mastermind-sidecar \
  --update-secrets=/secrets/sa.json=mastermind-sa:latest \
  --set-env-vars FIREBASE_SERVICE_ACCOUNT=/secrets/sa.json
```

## Point the site at it

Cloud Run gives a stable HTTPS URL, so this is a one-time step — unlike the
tunnel, which changes every restart:

```bash
cd sidecar
node publish_sidecar_url.mjs --url wss://mastermind-sidecar-xxxxx-uc.a.run.app
```

After that the bare link works with no laptop involved. `npm run tunnel` and
`npm run publish:url` become unnecessary.

## What this does and does not buy

**Buys you:** the service stays up when your laptop sleeps; no expiring tunnel;
automatic restart on crash; one stable address.

**Does not buy you:** measurements for distant visitors. Frames cross the wire
as raw RGB at roughly 55 Mbps (320x240) or 221 Mbps (640x480), and fps cannot
drop below Presage's 25fps floor. A judge on venue WiFi will connect and then
stall at "Hold still and record". Only compressing the frames fixes that, and
that needs validating against the raw path first — lossy compression attacks the
~1% colour change Presage reads a pulse from.

**Costs you:** every visitor's measurement bills your Presage credits, and their
camera frames land on your server rather than staying on their machine.
