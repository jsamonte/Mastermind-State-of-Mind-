# Presage sidecar

Holds the SmartSpectra SDK that a browser cannot, and streams composure
readings to the Flutter web app.

## Why this exists

Presage SmartSpectra has **no browser JavaScript SDK and no REST API**. The
supported surfaces are Android, iOS, C++ and Node.js/Electron. A website
therefore cannot call it directly.

The Node SDK's `useCustomInput()` / `sendFrame()` is the way through: it accepts
raw RGB buffers instead of opening a camera. So the browser keeps the webcam and
pushes frames here over a WebSocket. Full reasoning in
[../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

## Run it

```bash
npm install
cp .env.example .env     # then paste your Presage API key in
npm start
```

```bash
npm run start:mock       # no SDK and no key needed
npm run demo:calm        # deterministic green verdict
npm run demo:agitated    # deterministic red verdict
npm test                 # composure + protocol + end-to-end
```

The server falls back to the mock source on its own, loudly, if the key is
missing or the platform has no native runtime — it never pretends simulated
vitals are real.

## This machine cannot run the real SDK

Presage publishes native runtimes for `win32-x64`, `linux-x64`, `linux-arm64`
and `darwin-arm64`. There is **no `win32-arm64`**, and this laptop is Windows on
ARM64, so `require()` fails by design.

Either run the sidecar under **WSL2 on Ubuntu 22.04+** (reports `linux-arm64`,
which is published — and `node_modules` already contains that runtime, so the
same checkout works unchanged), or install an **x64 Node** build and let it run
under Prism emulation (reports `win32-x64`).

Because the sidecar takes frames over a socket and never opens a camera, WSL's
lack of webcam passthrough does not matter. That is the cleaner option.

## Ports and endpoints

One port, 8787, serves both.

| | |
| --- | --- |
| `ws://127.0.0.1:8787` | frames in, readings out |
| `GET /health` | source, protocol version, whether auth is configured |
| `POST /auth/firebase` | `{idToken}` → `{firebaseToken, uid, claims}` |

Loopback only, and CORS accepts loopback origins only. This process holds the
Presage API key and a Firebase private key; it should not answer to a page from
anywhere else.

## WebSocket protocol

Binary messages are frames — layout in [src/protocol.mjs](src/protocol.mjs),
mirrored in `app/lib/src/casing/frame_codec.dart`. Text messages are JSON.

**Client → sidecar**

| `type` | Payload |
| --- | --- |
| `begin` | `{durationMs, thresholds:{green, amber}}` |
| `end` | stop early; the pending reading still resolves |
| `ping` | `{t}` → `pong` |

**Sidecar → client**

| `type` | Meaning |
| --- | --- |
| `ready` | handshake: `{source, protocolVersion, scenario?}` |
| `casing` | the window started |
| `reading` | live composure, ~2/second |
| `final` | the verdict, with `reason` for why it ended |
| `status` | pipeline state and Presage validation hints |
| `error` | `{code, message, fatal}` |

## Layout

| File | Role |
| --- | --- |
| `src/server.mjs` | HTTP + WebSocket, session lifecycle |
| `src/smartspectra.mjs` | the real SDK behind a small interface |
| `src/mock.mjs` | a stand-in implementing that same interface |
| `src/composure.mjs` | signals → one 0..100 score, with named weights |
| `src/protocol.mjs` | the frame wire format |
| `src/auth.mjs` | Auth0 JWKS verify → Firebase custom token |

## Two rules worth keeping

**Fail closed.** Missing or low-confidence data produces `inconclusive`, never
`green`. A gate that opens when the sensor breaks is not a gate. The e2e test
asserts this with a deliberately low-confidence scenario.

**This is not a security boundary.** The sidecar runs on the user's own machine,
so a determined user can always point a camera at someone calm. Mastermind is a
commitment device for a willing participant, not an adversarial control.
