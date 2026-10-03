# Mastermind

**You can't rob a vault in a bad mood.**

Mastermind sits between you and the actions you'll regret. The 2am text. The
checkout button at the end of a bad day. You plan the job while you're calm;
Mastermind makes sure the person who *executes* it is calm too.

It reads your physiological state through your webcam — pulse, breathing rate,
heart-rate variability, electrodermal arousal, facial expression — and keeps the
vault shut until you're actually in a state to be trusted with the contents.

> Built for **Rowdy Hacks 2026**, and submitted for **Best Use of Gemini API**,
> **Best Use of Presage** and **Best Use of Auth0**. The heist conceit is
> load-bearing: the thing in the vault is your own impulse, and you are both the
> mastermind and the mark.

Don't get fooled by scammers, but more importantly don't fool yourself. Make
sure you are in a good state of mind before doing anything important, such as
before making a big purchase, giving information to sketchy calls,
double-texting, confessing to your crush, or breaking up with your crush.

It can help the elderly and the vulnerable — the people scammers go after
hardest — avoid being scammed, by giving them a way to check their current
state of mind before making a major decision. Use Mastermind State of Mind
today!

## The job

| Term | What it is |
| --- | --- |
| **Job** | An action you've chosen to gate: a text to send, a purchase to make |
| **Blueprint** | Your rules — which jobs need a check, and how calm you must be |
| **Casing** | A ~30s Presage measurement from your webcam |
| **Intel** | The composure reading that comes back |
| **The Vault** | Holds the job until the reading clears it |
| **Lie low** | The cooling-off timer when you're close but not clear |
| **The Record** | Every attempt, logged — so you can see your own patterns |

## Verdicts

- **GREEN** — vault opens, job released.
- **AMBER** — you're warm. Lie low, then case it again.
- **RED** — vault stays shut. The job is still there tomorrow.

## Then it talks to you

A verdict on its own is a locked door with no explanation. So after every
reading Mastermind opens a conversation: it tells you what was actually
measured, asks what decision you're facing, and helps you work out whether to
act now or wait — with something concrete to settle and a realistic better time.

It can also tell you to go ahead. An app that always says wait gets ignored, and
deserves to be.

The conversation is **advisory only** and never changes the verdict. The vault
answers to your pulse, not to being talked round — otherwise a commitment device
is just a negotiation.

## Stack

- **Flutter web** — the frontend (`app/`), responsive for desktop and mobile
- **Presage SmartSpectra** — state-of-mind sensing, via a Node sidecar (`sidecar/`)
- **Gemini** — the conversation after a reading, proxied through the sidecar
- **Firebase** — Firestore for jobs, blueprints and the record (`firebase/`)
- **Auth0** — login, exchanged for a Firebase custom token in the sidecar

Three credentials live in `sidecar/.env` and none reach the browser: Presage,
Gemini, and the Firebase Admin service account. Anything compiled into a Flutter
web bundle is public, which is a large part of why the sidecar exists.

## Run it

```bash
cd sidecar && npm install && cp .env.example .env   # paste your keys in
npm start                                           # ws + http on :8787

cd ../app && flutter run -d chrome                  # or: flutter build web
```

The sidecar falls back to a clearly-labelled mock source if the Presage key is
missing or the platform has no native runtime, so the whole app is usable
without a key. It never presents simulated vitals as real.

**One tab at a time.** The Presage SDK's native state is process-global, so the
sidecar hands it to a single connection and answers any other with
`sidecar_busy`. Two open tabs are not two measurements; before the guard
existed they were one corrupted one, failing on whichever tab was innocent.

### The hosted build

`https://mastermind-state-of-mind.web.app` serves the Flutter bundle, deployed
with `firebase deploy --only hosting`. The bundle still points at
`ws://127.0.0.1:8787`, which is loopback on **the visitor's** machine - so the
hosted page is fully working for whoever is running the sidecar, and stalls at
"Reading your state…" for everyone else. It is a demo you drive, not a link you
send. `?sidecar=wss://host:port` overrides the address if the sidecar is ever
published behind TLS.

Hosting it also means a second origin that contends for the same sidecar: a
localhost tab and a hosted tab are still two tabs.

## Docs

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — why the sidecar exists, and why
  that is not a choice. Read this first.
- [docs/MOBILE.md](docs/MOBILE.md) — what it takes to measure on a phone, and
  why the obvious shortcut is a bad idea.
- [sidecar/README.md](sidecar/README.md) — the wire protocol and endpoints.

## Health disclaimer

Presage SmartSpectra metrics are for **general wellness and informational
purposes only**. They are not FDA-cleared and must not be used for medical
diagnosis or treatment. Mastermind is a commitment device, not a clinical tool,
and its composure score is a deliberately simple heuristic over those signals.

The conversation is a tool for second-guessing a text message or a purchase. It
is not therapy and not mental-health advice, it is instructed not to diagnose,
and it is told to stop coaching and point to real help if someone is in crisis.
