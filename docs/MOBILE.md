# Running on mobile browsers

The app is responsive and works on a phone. Getting a *measurement* to work on a
phone has three hard constraints that are easy to discover at the worst moment,
so they are written down here.

## 1. The camera needs a secure context

`getUserMedia` only works in a secure context: **HTTPS, or localhost**. On a
desktop you hit `http://localhost:8080` and localhost counts, so everything
works and the problem stays hidden.

A phone cannot use your laptop's localhost. It hits `http://192.168.x.x:8080`,
which is **not** a secure context, and the browser refuses the camera outright.

The app detects this and shows a red banner instead of failing silently — see
`Config.isSecureContext` and `_InsecureContextWarning`. But detection is not a
fix. You need HTTPS.

## 2. An HTTPS page cannot open a `ws://` socket

Browsers block mixed content. The moment the page is served over HTTPS, the
sidecar has to be reachable over `wss://` too. `Config.sidecarUrl` upgrades the
scheme automatically when the page is secure (except for loopback, which is
exempt), so a stale `ws://` becomes a clear connection error rather than a
silent security block.

## 3. Raw frames are big, and compressing them is not obviously safe

Presage does remote photoplethysmography — it recovers a pulse from very small
colour changes in skin. The wire format is therefore **raw RGB24**:

| Capture | Per frame | At 15fps |
| --- | --- | --- |
| 640x480 (desktop default) | 921 KB | ~13.8 MB/s |
| 320x240 (mobile default) | 230 KB | ~3.4 MB/s (~27 Mbps) |

3.4 MB/s is fine over good LAN WiFi and marginal over mobile data.

The obvious fix — send JPEG and decode in the sidecar — is **not** obviously
safe here, and this is worth being honest about rather than shipping quietly.
JPEG's chroma subsampling and quantisation attack exactly the signal rPPG
depends on. It might work at high quality; it might produce confident-looking
numbers derived from compression artefacts. That is the worst possible failure
mode for an app whose whole job is telling you something true about yourself.
Nobody has measured it, so the code does not do it.

**If you want real measurement on mobile, the honest architecture is Presage's
native Android or iOS SDK**, which runs on-device and never streams frames at
all. A mobile *website* cannot run the SDK — that is the same constraint
described in [ARCHITECTURE.md](ARCHITECTURE.md), and no amount of frontend work
removes it.

## Making it work anyway, for a demo

### Option A — tunnel (recommended, works on any network)

Two tunnels: one for the app, one for the sidecar.

```bash
# terminal 1 — the sidecar
cd sidecar && npm start

# terminal 2 — serve the built app
cd app/build/web && py -m http.server 8080

# terminal 3 — HTTPS for the app
cloudflared tunnel --url http://localhost:8080

# terminal 4 — WSS for the sidecar
cloudflared tunnel --url http://localhost:8787
```

Open the app tunnel's HTTPS URL on the phone, and point it at the sidecar
tunnel with the query parameter:

```
https://<app-tunnel>.trycloudflare.com/?sidecar=wss://<sidecar-tunnel>.trycloudflare.com
```

`?sidecar=` is read by `Config.sidecarUrl`, so no rebuild is needed to retarget.

Note what this means: your webcam frames leave your machine and cross a third
party's network. For a hackathon demo of your own face that is a decision you
can make knowingly — just make it knowingly.

### Option B — local HTTPS on the LAN

Keeps the frames on your own network, costs more setup. Use `mkcert` to make a
cert for your LAN IP, install the root CA on the phone, and serve both the app
and the sidecar over TLS. The sidecar currently listens on plain `ws://`
loopback, so this needs a TLS terminator in front of it (Caddy does it in about
four lines) or a change to `server.mjs` to take a cert.

## What the app already does for mobile

- **Responsive layout.** Single column below 860px, two-column above. The
  casing view takes over the screen on a phone instead of sitting in a side panel.
- **Smaller capture on mobile** — 320x240 instead of 640x480, because the frames
  cross a network rather than loopback.
- **Front camera**, via `facingMode: 'user'`.
- **`playsinline`** on the video element, or iOS Safari hijacks it fullscreen.
- **Mirrored preview**, because an unmirrored self-view reads as wrong.
- **Tracks are explicitly stopped** when a casing ends, so the camera indicator
  goes out. For an app that watches your face, leaving the light on is
  unacceptable.
- **A diagnostics panel** (ⓘ in the app bar) showing the resolved sidecar URL,
  whether the context is secure, the capture size and the estimated uplink —
  the four things that are wrong when mobile does not work.
