import { spawn } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const thisDir = dirname(fileURLToPath(import.meta.url));
const rootDir = resolve(thisDir, "..", "..");

export function getProjectRoot() {
  return rootDir;
}

// Spawn a child process, wiring stdout/stderr/exit to provided callbacks.
// Returns a handle with a kill() method for cancellation.
export function execute(cmd, args, { onStdout, onStderr, onExit }, extraEnv = {}) {
  const proc = spawn(cmd, args, {
    cwd: rootDir,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, ...extraEnv },
  });

  proc.stdout.on("data", (chunk) => {
    for (const row of chunk.toString().split("\n")) {
      if (row) onStdout(row);
    }
  });

  proc.stderr.on("data", (chunk) => {
    for (const row of chunk.toString().split("\n")) {
      if (row) onStderr(row);
    }
  });

  proc.on("close", (exitCode) => onExit(exitCode));
  proc.on("error", (err) => {
    onStderr(err.message);
    onExit(1);
  });

  return { kill: () => proc.kill("SIGTERM") };
}
