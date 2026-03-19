import { readdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const thisDir = dirname(fileURLToPath(import.meta.url));
const rootDir = resolve(thisDir, "..", "..");

// All recognized command names, in display order
const ALL_COMMANDS = [
  "build",
  "up",
  "down",
  "restart",
  "container-logs",
  "clean",
  "reset",
  "status",
  "list",
  "create",
  "remove",
  "update",
  "logs",
  "shell",
  "personas",
  "soft-reset",
  "set-key",
  "get-keys",
  "remove-key",
  "clear-keys",
  "providers",
  "mail",
  "read-mail",
  "sync-aliases",
  "snapshot-init",
  "snapshot",
  "snapshot-log",
  "snapshot-diff",
  "snapshot-status",
  "swarm-status",
  "swarm-stop",
  "health",
  "task-add",
  "task-list",
  "task-ready",
  "task-update",
  "task-graph",
  "artifact-list",
  "artifact-register",
  "artifact-get",
  "list-presets",
  "load-preset",
  "preset-info",
  "help",
  "clear",
  "exit",
  "quit",
];

// Commands whose second argument is an agent name
const AGENT_ARG_COMMANDS = new Set([
  "remove",
  "update",
  "logs",
  "shell",
  "set-key",
  "get-keys",
  "remove-key",
  "clear-keys",
  "mail",
  "read-mail",
]);

// Commands whose second argument is a preset file path
const PRESET_ARG_COMMANDS = new Set(["load-preset", "preset-info"]);

export function getAgentNames() {
  try {
    return readdirSync(resolve(rootDir, "home")).filter(
      (entry) => entry !== ".gitkeep" && !entry.startsWith(".")
    );
  } catch {
    return [];
  }
}

export function getPersonaNames() {
  try {
    return readdirSync(resolve(rootDir, "config", "personas"))
      .filter((entry) => entry.endsWith(".md"))
      .map((entry) => entry.replace(".md", ""));
  } catch {
    return [];
  }
}

export function getPresetFiles() {
  try {
    return readdirSync(resolve(rootDir, "presets"))
      .filter((entry) => entry.endsWith(".json"))
      .map((entry) => `presets/${entry}`);
  } catch {
    return [];
  }
}

export function complete(input) {
  const segments = input.trimStart().split(/\s+/);

  // Tab-complete the command name itself
  if (segments.length <= 1) {
    const stub = segments[0] || "";
    return ALL_COMMANDS.filter((name) => name.startsWith(stub));
  }

  const verb = segments[0];
  const tail = segments[segments.length - 1];
  const preceding = segments.length > 2 ? segments[segments.length - 2] : "";

  // Complete the value following --persona
  if (preceding === "--persona") {
    return getPersonaNames().filter((n) => n.startsWith(tail));
  }

  // Complete agent names as the first positional argument
  if (segments.length === 2 && AGENT_ARG_COMMANDS.has(verb)) {
    return getAgentNames().filter((n) => n.startsWith(tail));
  }

  // Complete preset file paths as the first positional argument
  if (segments.length === 2 && PRESET_ARG_COMMANDS.has(verb)) {
    return getPresetFiles().filter((f) => f.startsWith(tail));
  }

  return [];
}
