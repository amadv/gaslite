import { readFileSync, readdirSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { getContainerName } from "./container.mjs";
import { getPersonaNames, getPresetFiles } from "./completions.mjs";
import { resolvePresetPath, extractPresetVars } from "./preset-vars.mjs";

const thisDir = dirname(fileURLToPath(import.meta.url));
const rootDir = resolve(thisDir, "..", "..");

// Commands that require the container to be running before they can execute
const CONTAINER_REQUIRED = new Set([
  "list",
  "create",
  "remove",
  "update",
  "logs",
  "shell",
  "set-key",
  "get-keys",
  "remove-key",
  "clear-keys",
  "providers",
  "mail",
  "sync-aliases",
  "soft-reset",
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
]);

const COMMANDS = {
  // --- Container ---
  build: {
    description: "Build the Docker image",
    category: "Container",
    toSpawn: () => ({ cmd: "docker", args: ["compose", "build"] }),
  },
  up: {
    description: "Start the container",
    category: "Container",
    toSpawn: () => ({ cmd: "docker", args: ["compose", "up", "-d"] }),
  },
  down: {
    description: "Stop and remove the container",
    category: "Container",
    toSpawn: () => ({ cmd: "docker", args: ["compose", "down"] }),
  },
  restart: {
    description: "Restart the container",
    category: "Container",
    sequence: ["down", "up"],
  },
  "container-logs": {
    description: "View container logs",
    category: "Container",
    toSpawn: () => ({
      cmd: "docker",
      args: ["compose", "logs", "-f", "--timestamps"],
    }),
  },
  clean: {
    description: "Stop container, remove image",
    category: "Container",
    toSpawn: () => ({ cmd: "make", args: ["clean"] }),
  },
  reset: {
    description: "Full reset: stop container, remove image, wipe all data",
    category: "Container",
    builtin: true,
  },
  status: {
    description: "Show container and agent status",
    category: "Container",
    builtin: true,
  },

  // --- Agents ---
  list: {
    description: "List all agents and their status",
    category: "Agents",
    toSpawn: () => ({ cmd: "./scripts/list-agents.sh", args: [] }),
  },
  create: {
    description: "Create a new agent",
    usage:
      "create <name> [--persona <name>] [--instructions <text>] [--api-key <PROVIDER=key>]",
    category: "Agents",
    minArgs: 1,
    toSpawn: (args) => ({ cmd: "./scripts/create-agent.sh", args }),
  },
  remove: {
    description: "Remove an agent",
    usage: "remove <name>",
    category: "Agents",
    minArgs: 1,
    toSpawn: (args) => ({ cmd: "./scripts/remove-agent.sh", args }),
  },
  update: {
    description: "Update an agent's persona",
    usage: "update <name> --persona <name>",
    category: "Agents",
    minArgs: 1,
    toSpawn: (args) => ({ cmd: "./scripts/update-agent.sh", args }),
  },
  logs: {
    description: "Stream agent logs (Ctrl+C to stop)",
    usage: "logs <name>",
    category: "Agents",
    minArgs: 1,
    toSpawn: (args) => ({
      cmd: "docker",
      args: [
        "compose",
        "exec",
        "-T",
        getContainerName(),
        "journalctl",
        "-u",
        `agent@${args[0]}.service`,
        "-f",
        "--no-pager",
      ],
    }),
  },
  shell: {
    description: "Open a shell as an agent (hint only)",
    usage: "shell <name>",
    category: "Agents",
    minArgs: 1,
    builtin: true,
  },
  personas: {
    description: "List available personas",
    category: "Agents",
    builtin: true,
  },
  "soft-reset": {
    description: "Remove all agents and clear logs",
    category: "Agents",
    toSpawn: () => ({ cmd: "./scripts/soft-reset.sh", args: ["--yes"] }),
  },

  // --- API Keys ---
  "set-key": {
    description: "Set an API key for an agent",
    usage: "set-key <name> <PROVIDER=key>",
    category: "API Keys",
    minArgs: 2,
    toSpawn: (args) => ({
      cmd: "./scripts/manage-api-keys.sh",
      args: ["set", args[0], args.slice(1).join(" ")],
    }),
  },
  "get-keys": {
    description: "Show API keys for an agent (masked)",
    usage: "get-keys <name>",
    category: "API Keys",
    minArgs: 1,
    toSpawn: (args) => ({
      cmd: "./scripts/manage-api-keys.sh",
      args: ["get", args[0]],
    }),
  },
  "remove-key": {
    description: "Remove an API key from an agent",
    usage: "remove-key <name> <PROVIDER>",
    category: "API Keys",
    minArgs: 2,
    toSpawn: (args) => ({
      cmd: "./scripts/manage-api-keys.sh",
      args: ["remove", args[0], args[1]],
    }),
  },
  "clear-keys": {
    description: "Remove all API keys from an agent",
    usage: "clear-keys <name>",
    category: "API Keys",
    minArgs: 1,
    toSpawn: (args) => ({
      cmd: "./scripts/manage-api-keys.sh",
      args: ["clear", args[0]],
    }),
  },
  providers: {
    description: "List known API key provider names",
    category: "API Keys",
    toSpawn: () => ({
      cmd: "./scripts/manage-api-keys.sh",
      args: ["list-providers"],
    }),
  },

  // --- Mail ---
  mail: {
    description: "Send mail to an agent or alias",
    usage: 'mail <to> "<message>" [--from <name>] [--subject "<text>"]',
    category: "Mail",
    minArgs: 2,
    toSpawn: (args) => {
      // Parse: mail <to> <message> [--from X] [--subject X]
      const recipient = args[0];
      const spawnArgs = [recipient];
      let idx = 1;

      // Gather non-flag tokens as message content
      const bodyParts = [];
      while (idx < args.length && !args[idx].startsWith("--")) {
        bodyParts.push(args[idx]);
        idx++;
      }
      const body = bodyParts.join(" ");

      // Process flag pairs
      while (idx < args.length) {
        if (args[idx] === "--from" && args[idx + 1]) {
          spawnArgs.push("--from", args[idx + 1]);
          idx += 2;
        } else if (args[idx] === "--subject" && args[idx + 1]) {
          spawnArgs.push("--subject", args[idx + 1]);
          idx += 2;
        } else {
          idx++;
        }
      }

      spawnArgs.push("--", body);
      return { cmd: "./scripts/send-mail.sh", args: spawnArgs };
    },
  },
  "read-mail": {
    description: "Read an agent's mailbox",
    usage: "read-mail <name>",
    category: "Mail",
    minArgs: 1,
    builtin: true,
  },
  "sync-aliases": {
    description: "Regenerate mail aliases",
    category: "Mail",
    toSpawn: () => ({ cmd: "./scripts/sync-aliases.sh", args: [] }),
  },

  // --- Snapshots ---
  "snapshot-init": {
    description: "Initialize the snapshot repository",
    category: "Snapshots",
    toSpawn: () => ({ cmd: "./scripts/snapshot-agents.sh", args: ["init"] }),
  },
  snapshot: {
    description: "Take a snapshot of agent state",
    usage: 'snapshot ["message"]',
    category: "Snapshots",
    toSpawn: (args) => ({
      cmd: "./scripts/snapshot-agents.sh",
      args: ["create", ...(args.length > 0 ? [args.join(" ")] : [])],
    }),
  },
  "snapshot-log": {
    description: "Show snapshot history",
    category: "Snapshots",
    toSpawn: () => ({ cmd: "./scripts/snapshot-agents.sh", args: ["log"] }),
  },
  "snapshot-diff": {
    description: "Show changes since last snapshot",
    category: "Snapshots",
    toSpawn: () => ({ cmd: "./scripts/snapshot-agents.sh", args: ["diff"] }),
  },
  "snapshot-status": {
    description: "Summarize changes since last snapshot",
    category: "Snapshots",
    toSpawn: () => ({ cmd: "./scripts/snapshot-agents.sh", args: ["status"] }),
  },

  // --- Swarm ---
  "swarm-status": {
    description: "Show task board, health, costs, and events",
    usage: "swarm-status [--tasks] [--costs] [--events] [--json]",
    category: "Swarm",
    toSpawn: (args) => ({ cmd: "./scripts/swarm-status.sh", args }),
  },
  "swarm-stop": {
    description: "Stop all agents and the orchestrator",
    usage: 'swarm-stop [--reason "<text>"]',
    category: "Swarm",
    toSpawn: (args) => ({ cmd: "./scripts/stop-swarm.sh", args }),
  },
  health: {
    description: "Check agent heartbeat health",
    usage: "health [--stale-after <seconds>] [--json]",
    category: "Swarm",
    toSpawn: (args) => ({ cmd: "./scripts/check-health.sh", args }),
  },
  "task-add": {
    description: "Add a task to the shared board",
    usage:
      'task-add "<subject>" <owner> [--description "<text>"] [--blocked-by <task-id,...>]',
    category: "Swarm",
    minArgs: 2,
    toSpawn: (args) => {
      const subject = args[0];
      const owner = args[1];
      return {
        cmd: "./scripts/task.sh",
        args: ["add", subject, "--owner", owner, ...args.slice(2)],
      };
    },
  },
  "task-list": {
    description: "List all tasks on the board",
    usage: "task-list [--owner <name>] [--status <status>]",
    category: "Swarm",
    toSpawn: (args) => ({ cmd: "./scripts/task.sh", args: ["list", ...args] }),
  },
  "task-ready": {
    description: "List tasks ready to start (blockers satisfied)",
    usage: "task-ready [--owner <name>]",
    category: "Swarm",
    toSpawn: (args) => ({ cmd: "./scripts/task.sh", args: ["ready", ...args] }),
  },
  "task-update": {
    description: "Update a task's status",
    usage: 'task-update <id> <status> [--result "<text>"]',
    category: "Swarm",
    minArgs: 2,
    toSpawn: (args) => {
      const taskId = args[0];
      const newStatus = args[1];
      return {
        cmd: "./scripts/task.sh",
        args: ["update", taskId, "--status", newStatus, ...args.slice(2)],
      };
    },
  },
  "task-graph": {
    description: "Show task dependency graph",
    category: "Swarm",
    toSpawn: () => ({ cmd: "./scripts/task.sh", args: ["graph"] }),
  },
  "artifact-list": {
    description: "List shared artifacts",
    usage: "artifact-list [--producer <name>]",
    category: "Swarm",
    toSpawn: (args) => ({
      cmd: "./scripts/artifact.sh",
      args: ["list", ...args],
    }),
  },
  "artifact-register": {
    description: "Register a shared artifact",
    usage: 'artifact-register <path> [--description "<text>"]',
    category: "Swarm",
    minArgs: 1,
    toSpawn: (args) => ({
      cmd: "./scripts/artifact.sh",
      args: ["register", ...args],
    }),
  },
  "artifact-get": {
    description: "Get metadata for an artifact",
    usage: "artifact-get <path>",
    category: "Swarm",
    minArgs: 1,
    toSpawn: (args) => ({
      cmd: "./scripts/artifact.sh",
      args: ["get", ...args],
    }),
  },

  // --- Presets ---
  "list-presets": {
    description: "List available workflow presets",
    category: "Presets",
    builtin: true,
  },
  "load-preset": {
    description: "Load a workflow preset",
    usage: "load-preset <file> [VAR=value ...] [--dry-run] [--skip-existing]",
    category: "Presets",
    minArgs: 1,
    toSpawn: (args) => ({ cmd: "./scripts/load-preset.sh", args }),
  },
  "preset-info": {
    description: "Show details of a preset file",
    usage: "preset-info <file>",
    category: "Presets",
    minArgs: 1,
    builtin: true,
  },

  // --- Meta ---
  help: {
    description: "Show available commands",
    category: "Meta",
    builtin: true,
  },
  clear: {
    description: "Clear the screen",
    category: "Meta",
    builtin: true,
  },
  exit: {
    description: "Exit the TUI",
    category: "Meta",
    builtin: true,
  },
  quit: { hidden: true, builtin: true },
};

export function parse(input) {
  const trimmed = input.trim();
  if (!trimmed) return null;

  // Tokenize while respecting single and double quoted strings
  const tokens = [];
  let buf = "";
  let openQuote = null;

  for (const ch of trimmed) {
    if (openQuote) {
      if (ch === openQuote) {
        openQuote = null;
      } else {
        buf += ch;
      }
    } else if (ch === '"' || ch === "'") {
      openQuote = ch;
    } else if (ch === " ") {
      if (buf) {
        tokens.push(buf);
        buf = "";
      }
    } else {
      buf += ch;
    }
  }
  if (buf) tokens.push(buf);

  const verb = tokens[0];
  const positionals = tokens.slice(1);
  const spec = COMMANDS[verb];

  if (!spec) {
    return {
      error: `Unknown command: '${verb}'. Type 'help' for available commands.`,
    };
  }

  if (spec.minArgs && positionals.length < spec.minArgs) {
    return { error: `Usage: ${spec.usage || verb}` };
  }

  return { name: verb, args: positionals, def: spec, raw: trimmed };
}

export function needsContainer(name) {
  return CONTAINER_REQUIRED.has(name);
}

export function getHelpLines() {
  const byCategory = {};

  for (const [verb, spec] of Object.entries(COMMANDS)) {
    if (spec.hidden) continue;
    const cat = spec.category || "Other";
    if (!byCategory[cat]) byCategory[cat] = [];
    byCategory[cat].push({ usage: spec.usage || verb, description: spec.description });
  }

  const output = [];
  for (const [cat, entries] of Object.entries(byCategory)) {
    output.push({ text: `  ${cat}:`, type: "info" });
    for (const entry of entries) {
      output.push({ text: `    ${entry.usage.padEnd(46)} ${entry.description}`, type: "stdout" });
    }
    output.push({ text: "", type: "stdout" });
  }

  return output;
}

export function getPersonaLines() {
  const names = getPersonaNames();
  const output = [
    { text: "  Available personas:", type: "info" },
    { text: "", type: "stdout" },
  ];

  for (const pname of names) {
    const label = pname === "base"
      ? `  ${pname} (applied to all agents)`
      : `  ${pname}`;
    output.push({ text: `    ${label}`, type: "stdout" });
  }

  output.push({ text: "", type: "stdout" });
  output.push({ text: "  Usage: create <name> --persona <name>", type: "stdout" });
  return output;
}

export function getReadMailLines(agentName) {
  // Reject suspicious agent names before touching the filesystem
  if (!/^[a-z_][a-z0-9_-]*$/.test(agentName)) {
    return [{ text: `  Invalid agent name: ${agentName}`, type: "stderr" }];
  }

  const maildirRoot = resolve(rootDir, "home", agentName, "Maildir");
  const DISPLAY_LIMIT = 50;
  const output = [];
  let shown = 0;
  let total = 0;

  for (const subfolder of ["new", "cur"]) {
    const folderPath = resolve(maildirRoot, subfolder);
    let entries;
    try {
      entries = readdirSync(folderPath)
        .filter((f) => !f.startsWith("."))
        .sort();
    } catch {
      continue;
    }

    total += entries.length;

    for (const filename of entries) {
      if (shown >= DISPLAY_LIMIT) break;
      try {
        const raw = readFileSync(resolve(folderPath, filename), "utf-8");
        shown++;
        const badge = subfolder === "new" ? " [NEW]" : "";
        output.push({ text: `--- Message ${shown}${badge} ---`, type: "info" });
        for (const row of raw.split("\n")) {
          output.push({ text: row, type: "stdout" });
        }
        output.push({ text: "", type: "stdout" });
      } catch {
        continue;
      }
    }
  }

  if (shown === 0) {
    return [{ text: `  No mail for ${agentName}.`, type: "info" }];
  }

  if (total > DISPLAY_LIMIT) {
    output.push({
      text: `  (showing ${DISPLAY_LIMIT} of ${total} messages)`,
      type: "info",
    });
  }

  return output;
}

export function getListPresetsLines() {
  const presets = getPresetFiles();

  if (presets.length === 0) {
    return [
      { text: "  No presets found in presets/", type: "info" },
      { text: "", type: "stdout" },
      { text: "  Create a JSON file in presets/ to get started.", type: "stdout" },
    ];
  }

  const output = [
    { text: "  Available presets:", type: "info" },
    { text: "", type: "stdout" },
  ];

  for (const filePath of presets) {
    const abs = resolve(rootDir, filePath);
    const shortName = filePath.replace("presets/", "").replace(".json", "");
    try {
      const data = JSON.parse(readFileSync(abs, "utf-8"));
      const desc = data.description || "No description";
      output.push({ text: `    ${shortName.padEnd(25)} ${desc}`, type: "stdout" });
    } catch {
      output.push({ text: `    ${shortName.padEnd(25)} (error reading file)`, type: "stderr" });
    }
  }

  output.push({ text: "", type: "stdout" });
  output.push({ text: "  Usage: load-preset <file> [--dry-run] [--skip-existing]", type: "stdout" });
  return output;
}

export function getPresetInfoLines(file) {
  const abs = resolvePresetPath(file);
  if (!abs) {
    return [{ text: `  Preset not found: ${file}`, type: "stderr" }];
  }

  let data;
  try {
    data = JSON.parse(readFileSync(abs, "utf-8"));
  } catch (err) {
    return [{ text: `  Error reading ${file}: ${err.message}`, type: "stderr" }];
  }

  const shortName = file.replace("presets/", "").replace(".json", "");
  const output = [];

  output.push({ text: `  Preset: ${shortName}`, type: "info" });
  output.push({ text: `  Description: ${data.description || "No description"}`, type: "stdout" });
  output.push({ text: "", type: "stdout" });

  if (data.agents && data.agents.length > 0) {
    output.push({ text: "  Agents:", type: "info" });
    for (const agent of data.agents) {
      const personaNote = agent.persona ? ` (persona: ${agent.persona})` : "";
      output.push({ text: `    ${agent.name}${personaNote}`, type: "stdout" });
    }
    output.push({ text: "", type: "stdout" });
  }

  if (data.tasks && data.tasks.length > 0) {
    output.push({ text: "  Tasks:", type: "info" });
    for (const task of data.tasks) {
      const ownerTag = task.owner ? ` [${task.owner}]` : "";
      const blockedTag =
        task.blocked_by && task.blocked_by.length > 0
          ? ` (blocked by: ${task.blocked_by.join(", ")})`
          : "";
      const idPrefix = task.id ? `${task.id}: ` : "";
      output.push({ text: `    ${idPrefix}${task.subject}${ownerTag}${blockedTag}`, type: "stdout" });
    }
    output.push({ text: "", type: "stdout" });
  }

  const vars = extractPresetVars(abs);
  if (vars.length > 0) {
    output.push({ text: "  Variables:", type: "info" });
    for (const v of vars) {
      const defaultNote = v.defaultValue !== null
        ? ` (default: ${v.defaultValue})`
        : " (required)";
      const envNote = process.env[v.name] ? ` [set: ${process.env[v.name]}]` : "";
      output.push({ text: `    ${v.name}${defaultNote}${envNote}`, type: "stdout" });
    }
    output.push({ text: "", type: "stdout" });
  }

  return output;
}

export { COMMANDS };
