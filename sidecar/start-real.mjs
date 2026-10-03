/**
 * Launcher for the real Presage runtime.
 *
 * Why this exists: @smartspectra/node-sdk publishes no win32-arm64 native
 * runtime, so on this laptop the sidecar has to run under an x64 Node build
 * (Prism emulation reports win32-x64, which IS published). See sidecar/README.md.
 *
 * Why it is a script and not an npm one-liner: the previous
 * `"${NODE_X64:-C:/...}"` form is POSIX parameter expansion. It works in Git
 * Bash and fails in cmd.exe with "The filename, directory name, or volume label
 * syntax is incorrect", because cmd passes the whole ${...} through as a
 * literal path. npm picks the shell, so the script must not depend on which one.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const nodeX64 = process.env.NODE_X64 ?? "C:/Users/jared/node-x64/node.exe";

if (!existsSync(nodeX64)) {
  console.error(`\nx64 Node not found at: ${nodeX64}`);
  console.error("Set NODE_X64 to an x64 Node binary, or run `npm run start:mock`.");
  console.error("Without it the real SDK cannot load on Windows ARM64.\n");
  process.exit(1);
}

const child = spawn(
  nodeX64,
  ["--env-file-if-exists=.env", path.join("src", "server.mjs"), ...process.argv.slice(2)],
  { cwd: here, stdio: "inherit" },
);

child.on("exit", (code, signal) => process.exit(signal ? 1 : (code ?? 0)));
