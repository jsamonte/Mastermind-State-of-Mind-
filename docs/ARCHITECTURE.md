# Architecture

## The constraint that shapes everything

**Presage SmartSpectra cannot run in a browser.** There is no browser JavaScript
SDK and no documented REST endpoint that takes a video and returns metrics. The
published surfaces are Android (Kotlin), iOS (Swift), C++, and Node.js/Electron.

Some search engines will tell you there is a "Web (JavaScript/TypeScript)" SDK.
The official docs and the SDK repo both contradict this. Do not plan around it.

So a *website* cannot call Presage directly. What makes it possible anyway is
one method on the Node SDK:

```js
sdk.useCustomInput(FrameTransform.kNone);
sdk.sendFrame(rgbBuf, width, height, width * 3, PixelFormat.kRGB, captureTsUs);
```

`useCustomInput()` means the SDK does not want a camera — it wants buffers. So
the browser keeps ownership of the webcam and ships frames to a local Node
process that holds the SDK.

```
┌─────────────────────────────┐
│ Flutter web  (app/)         │
│  getUserMedia → <canvas>    │
│  → RGB bytes                │
└──────────┬──────────────────┘
           │  WebSocket :8787
           │  binary frame: [header][rgb bytes]
           ▼
┌─────────────────────────────┐
│ Node sidecar  (sidecar/)    │
│  @smartspectra/node-sdk     │
│  useCustomInput()/sendFrame │
└──────────┬──────────────────┘
           │  JSON readings back over the same socket
           ▼
     composure score → verdict → Firestore (the record)
```

The sidecar never opens a camera. That matters more than it sounds: it means the
sidecar can live anywhere that can run the SDK, including a container or WSL,
because camera passthrough is irrelevant.

## This laptop cannot run the sidecar natively

The native runtime ships as per-platform npm packages. Verified against npm
on 2026-10-03:

| Target | Published |
| --- | --- |
| `win32-x64` | 3.4.0 |
| `linux-x64` | 3.4.0 |
| `linux-arm64` | 3.4.0 |
| `darwin-arm64` | 3.4.0 |
| **`win32-arm64`** | **not published** |

This machine is Windows on ARM64 (Snapdragon), so `require()` of the SDK fails
with an error naming the missing `@smartspectra/node-sdk-win32-arm64`.

Two ways out:

1. **WSL2 on Ubuntu 22.04+** → reports `linux-arm64`, which *is* published, and
   runs natively. Because the sidecar needs no camera, WSL's lack of webcam
   passthrough costs nothing. The browser on Windows reaches it over
   `localhost` (WSL2 forwards localhost). **Recommended.**
2. **An x64 Node build under Prism emulation** → reports `win32-x64` and loads
   the emulated runtime. Fewer moving parts, but this is real-time video
   processing running emulated, so treat throughput as unproven.

`sidecar/src/mock.mjs` exists so the entire app — vault logic, UI, Firestore
writes — can be built and demoed on this laptop with no SDK at all. The real
source and the mock implement the same interface.

## Auth0 + Firebase

Auth0 owns identity; Firestore needs a Firebase identity to enforce rules. They
are bridged with a custom token, minted **in the sidecar** — not in a Cloud
Function:

```
Auth0 login (PKCE, in-browser)
   └─► id_token ──► sidecar POST /auth/firebase
                      verifies the Auth0 JWT against Auth0's JWKS
                      admin.auth().createCustomToken(auth0_sub)
                    └─► signInWithCustomToken() in the Flutter app
                        └─► request.auth.uid in firestore.rules
```

The Auth0 `sub` becomes the Firebase uid, so rules key off one id everywhere.

**Why not a Cloud Function.** The Firebase project is on the Spark (no-cost)
plan, and Functions requires Blaze, which requires a card. Rather than gate the
project on billing, the minter moved into the process that has to be running
anyway.

This keeps the rule that actually matters. "Never mint tokens client-side" is
intact — the sidecar is not the client. It already holds the Presage API key, it
is already required for any measurement, and it is already the one trusted local
process in the design, which is the exact shape a token minter needs. The Admin
SDK private key (`sidecar/serviceAccountKey.json`, gitignored) never reaches the
browser.

The tradeoff is that login now depends on the sidecar being up, which for a
local demo costs nothing. If this were ever deployed for real users the minter
moves server-side and nothing else changes: the browser calls one endpoint
either way.

## Data model (Firestore)

```
users/{uid}
  blueprint: { purchaseCeiling, minComposure, lieLowMinutes, gatedChannels[] }

users/{uid}/jobs/{jobId}
  kind: "message" | "purchase"
  payload: { ... }           # the text, or the cart
  state: "planned" | "locked" | "released" | "abandoned"
  createdAt, releasedAt

users/{uid}/attempts/{attemptId}
  jobId, composure, verdict, signals{}, measuredAt
```

The `attempts` collection is the product's real payload: it is a log of when you
reach for things and what state you were in. That is the thing nobody else is
building.

## Why the score is a heuristic, deliberately

Presage returns pulse rate, breathing rate, HRV (RMSSD/SDNN/meanNN/Baevsky),
an EDA arousal trace, and facial expression classification. Mapping those onto
"are you in a good state of mind" is not a solved problem and we are not going
to pretend otherwise in a weekend.

`sidecar/src/composure.mjs` keeps the mapping in one small, readable, tunable
file with every weight named and every assumption commented. Honest and legible
beats an opaque formula that looks authoritative.
