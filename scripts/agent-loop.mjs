#!/usr/bin/env node
// agent-loop.mjs — One autonomous work cycle using the Claude Agent SDK
//
// Executes a single iteration of the agent's autonomous loop:
//   1. Check inbound mail and outstanding TODOs
//   2. Process work items per CLAUDE.md instructions
//   3. Exit (the caller in run-agent.sh handles sleep and re-invocation)
//
// Environment variables consumed:
//   ANTHROPIC_API_KEY       — Required (loaded by run-agent.sh)
//   AGENT_USER              — Set by run-agent.sh
//   HOME                    — Agent home directory (provided by systemd)
//   AGENT_MODEL             — Optional model override (default: claude-opus-4-6)
//   AGENT_MAX_TURNS         — Optional turn cap per cycle (default: 50)
//   AGENT_CYCLE_TIMEOUT_MS  — Optional cycle timeout in ms (default: 300000 / 5 min)
//
// Exit codes:
//   0 — Cycle finished successfully (or no work found)
//   1 — Cycle failed: recoverable error (worth retrying)
//   2 — Cycle failed: unrecoverable (bad config, wrong API key — do not retry)
//   3 — Cycle failed: timed out

import {
  readFileSync,
  writeFileSync,
  appendFileSync,
  mkdirSync,
} from "node:fs";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";

const WORKER = process.env.AGENT_USER || process.env.USER || "unknown";
const WORK_HOME = process.env.HOME || `/home/${WORKER}`;
const CHOSEN_MODEL = process.env.AGENT_MODEL || "claude-opus-4-6";
const TURN_CAP = parseInt(process.env.AGENT_MAX_TURNS || "50", 10);
const TIMEOUT_MS = parseInt(
  process.env.AGENT_CYCLE_TIMEOUT_MS || "300000",
  10,
);

const OUTPUT_DIR = join(WORK_HOME, ".agent-results");
const AUDIT_LOG = join(WORK_HOME, ".agent-events.jsonl");
const PULSE_FILE = join(WORK_HOME, ".agent-heartbeat");

// Ensure the results directory is present
try {
  mkdirSync(OUTPUT_DIR, { recursive: true });
} catch {}

// Append a structured event to the audit log
function recordEvent(kind, details = {}) {
  const entry = {
    timestamp: new Date().toISOString(),
    agent: WORKER,
    event: kind,
    ...details,
  };
  try {
    appendFileSync(AUDIT_LOG, JSON.stringify(entry) + "\n");
  } catch {}
}

// Write a liveness marker so external watchers can detect stuck cycles
function updatePulse(phase) {
  try {
    writeFileSync(
      PULSE_FILE,
      JSON.stringify({
        agent: WORKER,
        phase,
        timestamp: new Date().toISOString(),
        pid: process.pid,
      }),
    );
  } catch {}
}

// Persist a structured cycle summary to disk
function saveCycleSummary(data) {
  const fname = `cycle-${new Date().toISOString().replace(/[:.]/g, "-")}.json`;
  try {
    writeFileSync(join(OUTPUT_DIR, fname), JSON.stringify(data, null, 2));
  } catch {}
}

// Map an error to the appropriate exit code
function mapErrorToCode(err) {
  const text = (err.message || "").toLowerCase();
  // Unrecoverable: auth/config problems
  if (
    text.includes("invalid api key") ||
    text.includes("authentication") ||
    text.includes("invalid_api_key") ||
    text.includes("permission denied") ||
    text.includes("model not found") ||
    text.includes("invalid model")
  ) {
    return 2; // unrecoverable
  }
  // Timeout category
  if (
    text.includes("abort") ||
    text.includes("timeout") ||
    text.includes("timed out")
  ) {
    return 3; // timeout
  }
  // Everything else: recoverable
  return 1;
}

// Load the assembled persona document (base + specialist role + custom instructions)
let workerPersona = "";
try {
  workerPersona = readFileSync(join(WORK_HOME, "agents.md"), "utf-8").trim();
} catch {
  console.log("[agent-loop] No agents.md found, proceeding without persona");
}

const WAKE_PROMPT = `You are agent "${WORKER}" waking up for a work cycle.

Read your CLAUDE.md and follow the workflow described there. It covers how to check for work, process tasks, and report results.

If there is no new mail and no pending tasks in TODO.md, you are done — exit cleanly.

Be efficient. Complete what you can in this cycle. You will wake up again soon.`;

async function executeCycle() {
  const abort = new AbortController();
  const startedAt = Date.now();

  updatePulse("starting");
  recordEvent("cycle_start", { model: CHOSEN_MODEL, maxTurns: TURN_CAP });

  // Abort the cycle if it exceeds the configured timeout
  const watchdog = setTimeout(() => {
    console.error(
      `[agent-loop] Cycle exceeded ${TIMEOUT_MS}ms timeout, aborting`,
    );
    recordEvent("cycle_timeout", { timeout_ms: TIMEOUT_MS });
    abort.abort();
  }, TIMEOUT_MS);

  let turnsUsed = 0;
  let spendUsd = null;
  let outcomeSubtype = "unknown";

  try {
    const stream = query({
      prompt: WAKE_PROMPT,
      options: {
        model: CHOSEN_MODEL,
        maxTurns: TURN_CAP,
        cwd: WORK_HOME,
        abortSignal: abort.signal,
        allowedTools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"],
        permissionMode: "bypassPermissions",
        systemPrompt: {
          type: "preset",
          preset: "claude_code",
          append: [
            `You are an autonomous agent named "${WORKER}". You run on a shared Unix system. Follow your CLAUDE.md instructions precisely. Be concise. Work independently. Do not ask for user input — make decisions on your own.`,
            workerPersona ? `\n\n## Your Persona\n\n${workerPersona}` : "",
          ].join(""),
        },
        settingSources: ["project"],
      },
    });

    for await (const msg of stream) {
      updatePulse("running");

      if (msg.type === "assistant" && msg.message?.content) {
        for (const block of msg.message.content) {
          if ("text" in block && block.text) {
            const preview =
              block.text.length > 200
                ? block.text.substring(0, 200) + "..."
                : block.text;
            console.log(`[agent-loop] ${preview}`);
          }
        }
      }

      if (msg.type === "result") {
        outcomeSubtype = msg.subtype || "unknown";
        turnsUsed = msg.num_turns || 0;
        spendUsd = msg.total_cost_usd ?? null;

        if (msg.subtype === "success") {
          console.log(
            `[agent-loop] Cycle complete: turns=${turnsUsed}` +
              (spendUsd != null ? ` cost=$${spendUsd.toFixed(4)}` : ""),
          );
        } else {
          console.error(
            `[agent-loop] Cycle ended with ${msg.subtype}` +
              (msg.errors ? `: ${JSON.stringify(msg.errors)}` : ""),
          );
        }
      }
    }

    const duration = Date.now() - startedAt;

    saveCycleSummary({
      agent: WORKER,
      model: CHOSEN_MODEL,
      status: outcomeSubtype === "success" ? "success" : "failure",
      subtype: outcomeSubtype,
      turns: turnsUsed,
      cost_usd: spendUsd,
      elapsed_ms: duration,
      timestamp: new Date().toISOString(),
    });

    recordEvent("cycle_end", {
      status: outcomeSubtype === "success" ? "success" : "failure",
      turns: turnsUsed,
      cost_usd: spendUsd,
      elapsed_ms: duration,
    });

    updatePulse("idle");
    return outcomeSubtype === "success" ? 0 : 1;
  } finally {
    clearTimeout(watchdog);
  }
}

// --- Entry point ---
try {
  // Fail fast if there is no API key — no point burning a cycle
  if (!process.env.ANTHROPIC_API_KEY) {
    console.error("[agent-loop] FATAL: ANTHROPIC_API_KEY is not configured");
    recordEvent("fatal_error", { error: "ANTHROPIC_API_KEY not set" });
    updatePulse("error");
    process.exit(2);
  }

  console.log(
    `[agent-loop] Cycle starting for ${WORKER} (model=${CHOSEN_MODEL}, maxTurns=${TURN_CAP}, persona=${workerPersona ? "loaded" : "none"})`,
  );
  const code = await executeCycle();
  console.log(`[agent-loop] Cycle done (exit=${code})`);
  process.exit(code);
} catch (err) {
  const code = mapErrorToCode(err);
  console.error(`[agent-loop] Uncaught error (exit=${code}): ${err.message}`);
  recordEvent("cycle_error", { error: err.message, exit_code: code });
  updatePulse("error");

  saveCycleSummary({
    agent: WORKER,
    model: CHOSEN_MODEL,
    status: "error",
    error: err.message,
    exit_code: code,
    timestamp: new Date().toISOString(),
  });

  process.exit(code);
}
