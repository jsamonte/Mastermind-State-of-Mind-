# Mastermind

**You can't rob a vault in a bad mood.**

Mastermind sits between you and the actions you'll regret. The 2am text. The
checkout button at the end of a bad day. You plan the job while you're calm;
Mastermind makes sure the person who *executes* it is calm too.

It reads your physiological state through your webcam — pulse, breathing rate,
heart-rate variability, electrodermal arousal, facial expression — and keeps the
vault shut until you're actually in a state to be trusted with the contents.

> Built for a heist-themed hackathon. The conceit is load-bearing: the thing in
> the vault is your own impulse, and you are both the mastermind and the mark.

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

## Stack

- **Flutter web** — the frontend (`app/`)
- **Presage SmartSpectra** — state-of-mind sensing, via a Node sidecar (`sidecar/`)
- **Firebase** — Firestore for jobs/blueprints/record, Cloud Functions (`firebase/`)
- **Auth0** — login, exchanged for a Firebase custom token

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for why the sidecar exists —
it is not optional, and the reason is interesting.

## Health disclaimer

Presage SmartSpectra metrics are for **general wellness and informational
purposes only**. They are not FDA-cleared and must not be used for medical
diagnosis or treatment. Mastermind is a commitment device, not a clinical tool,
and its composure score is a deliberately simple heuristic over those signals.
