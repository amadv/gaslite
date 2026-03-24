import { execSync } from "node:child_process";

// Use env override or fall back to project default
const TARGET_CONTAINER = process.env.AGENT_HOST_CONTAINER || "gaslite";
const RUNTIME = process.env.RUNTIME || "docker";

export function getContainerName() {
  return TARGET_CONTAINER;
}

export function getContainerStatus() {
  // Ask Docker for the container state; treat anything non-running as down
  try {
    const raw = execSync(
      `${RUNTIME} inspect -f '{{.State.Status}}' ${TARGET_CONTAINER}`,
      { timeout: 3000, encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"] }
    ).trim();
    return raw === "running" ? "up" : "down";
  } catch {
    return "down";
  }
}
