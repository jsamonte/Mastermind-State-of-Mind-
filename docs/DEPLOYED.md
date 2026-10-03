# Making the deployed site actually work

The app is deployed at **https://mastermind-state-of-mind.web.app**. By default
that page loads, authenticates, and then cannot measure anything, because the
Presage sidecar runs on your machine's loopback. This is how to connect them.

## Why the obvious thing fails

A public HTTPS page cannot reach `127.0.0.1`. Verified in Chrome from the live
site:

```
WebSocket to ws://127.0.0.1:8787 -> net::ERR_BLOCKED_BY_LOCAL_NETWORK_ACCESS_CHECKS
fetch http://127.0.0.1:8787/health -> blocked by CORS policy:
    "Permission was denied for this request to access the `loopback` address space."
```

This is **not** mixed content, and no server header fixes it. It is Chrome's
**Local Network Access** policy: a public site reaching into the local address
space is blocked before CORS is consulted, and a WebSocket has no preflight to
opt in with. Allowing the origin server-side is necessary but not sufficient.

So the sidecar has to reach the browser as a *public* HTTPS/WSS origin. A tunnel
does that.

## The setup

```bash
# 1. the sidecar, with the real Presage SDK
cd sidecar && npm run start:real

# 2. a public HTTPS front door for it
npm run tunnel          # prints https://<something>.trycloudflare.com
```

Then open the deployed site pointed at that address, with `wss://`:

```
https://mastermind-state-of-mind.web.app/?sidecar=wss://<something>.trycloudflare.com
```

The app **remembers** that value in `localStorage`. This matters: the Auth0
`redirect_uri` is the bare origin, so the query string is gone by the time you
come back signed in. Without remembering it the page would silently revert to
loopback after login — which the browser then blocks. To point it somewhere else
later, pass a new `?sidecar=`; to clear it, call `Config.forgetSidecar()`.

The sidecar must also allow the hosted origin. It does by default; override with
`EXTRA_ORIGINS` (comma-separated) in `sidecar/.env` if the hosting domain changes.

## Know what this means

**Your camera frames leave your machine.** They travel to Cloudflare's edge and
back down the tunnel. On loopback they never leave the laptop. For a demo of
your own face that is a decision you can reasonably make — make it knowingly,
and shut the tunnel down afterwards.

The quick tunnel is **ephemeral**: the hostname changes every run and there is no
uptime guarantee. Generate it fresh before a demo and paste the current URL.

## What a visitor without a sidecar sees

Anyone can open the deployed link, read the pitch, and sign in. They cannot take
a measurement — their browser would try *their* loopback, where nothing is
listening. The app surfaces that as a connection error rather than hanging, but
it is worth saying out loud: **the deployed link is the shop window; the
measurement happens wherever the sidecar is running.**

If you want a judge to take their own reading, they need the repo and a Presage
key, or you hand them your laptop.

## Deploying a new build

```bash
cd app && flutter build web --no-tree-shake-icons
cd .. && GOOGLE_APPLICATION_CREDENTIALS=sidecar/serviceAccountKey.json \
  npx firebase deploy --only hosting --project mastermind-state-of-mind
```

The service account has hosting permissions, so this needs no interactive login
— unlike `firestore:rules`, which 403s on a `serviceusage` precheck and goes
through `node firebase/deploy_rules.mjs` instead.
