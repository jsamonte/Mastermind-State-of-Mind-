/**
 * Keeps the public link working, on whatever machine this runs on.
 *
 * Presage's edge answers 403 to datacenter addresses - verified with a plain
 * unauthenticated request: 200 from a normal network, 403 from both Google
 * Cloud and Azure. So the measurement has to run on a machine with an ordinary
 * IP, and the hosted site reaches it through a tunnel. That machine does not
 * have to be anyone's laptop; any always-on computer on a normal network does,
 * and this script is deliberately not specific to one.
 *
 * What it supervises, because each of these took the link down at least once:
 *
 *   - the sidecar exiting, or wedging so it stops answering /health
 *   - the Cloudflare quick tunnel expiring ("Unauthorized: Tunnel not found"),
 *     which leaves cloudflared running and retrying forever against a hostname
 *     that no longer resolves
 *   - the tunnel coming back under a NEW hostname, so the address published for
 *     the app to discover is silently stale
 *
 * Run it instead of starting the two processes by hand:
 *
 *   cd sidecar && node run_public.mjs
 */
import { spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

const SIDECAR_PORT = Number(process.env.SIDECAR_PORT ?? 8787);
const HEALTH = `http://127.0.0.1:${SIDECAR_PORT}/health`;
const CLOUDFLARED = process.env.CLOUDFLARED ?? path.join(here, "bin", "cloudflared.exe");

/** How often to check that both halves are still working. */
const CHECK_EVERY_MS = 20_000;

/**
 * Health checks have to outlast a casing.
 *
 * A measurement is CPU-heavy and the SDK runs emulated on an ARM machine, so
 * a health reply can legitimately take a few seconds while one is in flight. Treating
 * that as death would restart the sidecar underneath whoever is being measured.
 */
const HEALTH_TIMEOUT_MS = 8_000;

/** Consecutive failed checks before acting. One blip is not an outage. */
const FAILURES_BEFORE_RESTART = 3;

const log = (...args) => console.log(new Date().toISOString().slice(11, 19), ...args);

let sidecar = null;
let tunnel = null;
let tunnelHost = null;
let published = null;
let sidecarFailures = 0;
let tunnelFailures = 0;
let stopping = false;

function startSidecar() {
  log("starting sidecar");
  sidecar = spawn(process.execPath, ["--env-file-if-exists=.env", "src/server.mjs"], {
    cwd: here,
    stdio: "inherit",
    windowsHide: true,
  });
  sidecar.on("exit", (code, signal) => {
    sidecar = null;
    if (stopping) return;
    log(`sidecar exited (code ${code}, signal ${signal}) - restarting`);
    setTimeout(startSidecar, 1_000);
  });
}

function startTunnel() {
  log("starting tunnel");
  tunnelHost = null;
  tunnel = spawn(
    CLOUDFLARED,
    ["tunnel", "--url", `http://127.0.0.1:${SIDECAR_PORT}`, "--no-autoupdate", "--protocol", "http2"],
    { cwd: here, stdio: ["ignore", "pipe", "pipe"], windowsHide: true },
  );

  const scan = (chunk) => {
    const text = chunk.toString();
    const found = text.match(/https:\/\/([a-z0-9-]+\.trycloudflare\.com)/);
    if (found && found[1] !== tunnelHost) {
      tunnelHost = found[1];
      log(`tunnel is ${tunnelHost}`);
      // Published only once it answers, by publishIfNeeded on the next check.
      published = null;
    }
    // cloudflared keeps running and retrying after a quick tunnel expires, so
    // the process being alive says nothing. This line is how we learn it died.
    if (text.includes("Unauthorized: Tunnel not found")) {
      log("tunnel expired - replacing it");
      replaceTunnel();
    }
  };
  tunnel.stdout.on("data", scan);
  tunnel.stderr.on("data", scan);

  tunnel.on("exit", (code, signal) => {
    tunnel = null;
    if (stopping) return;
    log(`tunnel exited (code ${code}, signal ${signal}) - restarting`);
    setTimeout(startTunnel, 1_000);
  });
}

let replacing = false;
function replaceTunnel() {
  if (replacing || stopping) return;
  replacing = true;
  const old = tunnel;
  tunnel = null;
  tunnelHost = null;
  published = null;
  try {
    old?.kill("SIGKILL");
  } catch {
    /* already gone */
  }
  setTimeout(() => {
    replacing = false;
    if (!stopping) startTunnel();
  }, 1_500);
}

async function reachable(url, timeout) {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(timeout) });
    if (!res.ok) return false;
    const body = await res.json().catch(() => null);
    return body?.ok === true;
  } catch {
    return false;
  }
}

/**
 * Tells the app where to find this machine.
 *
 * Reuses publish_sidecar_url.mjs rather than reimplementing it: that script
 * already refuses to publish an address whose /health does not answer, which is
 * the check that matters most here.
 */
async function publishIfNeeded() {
  if (!tunnelHost || published === tunnelHost) return;
  const url = `wss://${tunnelHost}`;
  const child = spawn(process.execPath, ["publish_sidecar_url.mjs", "--url", url], {
    cwd: here,
    stdio: "inherit",
    windowsHide: true,
  });
  const [code] = await once(child, "exit");
  if (code === 0) {
    published = tunnelHost;
    log(`published ${url}`);
  } else {
    log(`could not publish ${url} yet - will retry`);
  }
}

async function check() {
  if (stopping) return;

  if (sidecar) {
    if (await reachable(HEALTH, HEALTH_TIMEOUT_MS)) {
      sidecarFailures = 0;
    } else if (++sidecarFailures >= FAILURES_BEFORE_RESTART) {
      // Listening but not answering is the wedge this exists for. Killing it is
      // the only way back: a blocked native call cannot be interrupted.
      log(`sidecar unresponsive after ${sidecarFailures} checks - restarting it`);
      sidecarFailures = 0;
      const dying = sidecar;
      sidecar = null;
      try {
        dying.kill("SIGKILL");
      } catch {
        /* already gone */
      }
      setTimeout(startSidecar, 500);
      return;
    }
  }

  if (tunnelHost) {
    if (await reachable(`https://${tunnelHost}/health`, HEALTH_TIMEOUT_MS)) {
      tunnelFailures = 0;
      await publishIfNeeded();
    } else if (++tunnelFailures >= FAILURES_BEFORE_RESTART) {
      log(`tunnel ${tunnelHost} unreachable after ${tunnelFailures} checks - replacing it`);
      tunnelFailures = 0;
      replaceTunnel();
    }
  }
}

function shutdown() {
  if (stopping) return;
  stopping = true;
  log("shutting down");
  try {
    sidecar?.kill();
  } catch {
    /* already gone */
  }
  try {
    tunnel?.kill();
  } catch {
    /* already gone */
  }
  // Leaving the published address pointing at a machine that has stopped is
  // worse than publishing nothing: the app would stop looking elsewhere and
  // just fail. Mark it offline on the way out.
  const child = spawn(process.execPath, ["publish_sidecar_url.mjs", "--clear"], {
    cwd: here,
    stdio: "inherit",
    windowsHide: true,
  });
  once(child, "exit").finally(() => process.exit(0));
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

startSidecar();
startTunnel();
setInterval(() => void check(), CHECK_EVERY_MS);

log(`supervising: sidecar on ${SIDECAR_PORT}, tunnel, and the published address`);
log("press Ctrl+C to stop (the published address is marked offline on the way out)");
