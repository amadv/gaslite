#!/bin/bash
# run-agent.sh — Per-user entrypoint invoked by agent@<user>.service
#
# Executes as the worker account with that account's home as the working directory.
#
# Credential loading order:
#   1. Shared defaults from /etc/agent-api-keys/global.env (when present)
#   2. Per-account overrides from ~/.claude/api-keys.env (when present)
#   Account-level credentials take precedence over shared credentials.
#
# Drives autonomous work cycles via the Claude Agent SDK (agent-loop.mjs).
# Each cycle processes mail, handles TODOs, and records results.
#
# Exit code semantics (produced by agent-loop.mjs):
#   0 — Completed successfully (clear backoff counter)
#   1 — Recoverable failure (apply backoff, try again)
#   2 — Unrecoverable failure (halt service, do not retry)
#   3 — Timed out (light backoff, try again)
#
# Retry strategy: consecutive recoverable failures double the sleep interval up to a cap.
# Circuit breaker: after N consecutive failures, the loop halts and mails root.

set -euo pipefail

WORKER="$(whoami)"
WORK_DIR="$(pwd)"
WORKER_LOG="/home/${WORKER}/.agent.log"

stamp() {
    echo "[$(date -Iseconds)] agent(${WORKER}): $*" | tee -a "$WORKER_LOG"
}

stamp "Agent starting"
stamp "  Account: $WORKER"
stamp "  Workdir: $WORK_DIR"
stamp "  PID:     $$"

# Report on the persona document
PERSONA_DOC="/home/${WORKER}/agents.md"
if [[ -f "$PERSONA_DOC" ]]; then
    stamp "  Config:  $PERSONA_DOC (found)"
else
    stamp "  Config:  $PERSONA_DOC (not found)"
fi

SDK_CFG="/home/${WORKER}/.claude/config.json"
if [[ -f "$SDK_CFG" ]]; then
    stamp "  Claude:  $SDK_CFG (found)"
    # Pull the persona field out of the config for diagnostic logging
    ACTIVE_PERSONA="$(grep -o '"persona"[[:space:]]*:[[:space:]]*"[^"]*"' "$SDK_CFG" | head -1 | sed 's/.*"persona"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')" || true
    if [[ -n "${ACTIVE_PERSONA:-}" ]]; then
        stamp "  Persona: $ACTIVE_PERSONA"
    fi
else
    stamp "  Claude:  $SDK_CFG (not found)"
fi

# Read an env file and export all non-comment, non-empty KEY=VALUE pairs
import_env_file() {
    local path="$1"
    local label="$2"
    local tally=0
    if [[ -f "$path" ]] && [[ -r "$path" ]]; then
        while IFS='=' read -r varname varval; do
            [[ "$varname" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$varname" ]] && continue
            varname="$(echo "$varname" | xargs)"
            export "$varname=$varval"
            ((tally++)) || true
        done < "$path"
        if [[ $tally -gt 0 ]]; then
            stamp "  Credentials: loaded $tally from $label"
        fi
        return 0
    fi
    return 1
}

# Load shared credentials first (lowest priority)
SHARED_CREDS="/etc/agent-api-keys/global.env"
if [[ -f "$SHARED_CREDS" ]]; then
    import_env_file "$SHARED_CREDS" "global" || true
else
    stamp "  Credentials: no shared config"
fi

# Load per-account credentials (override shared)
ACCOUNT_CREDS="/home/${WORKER}/.claude/api-keys.env"
if [[ -f "$ACCOUNT_CREDS" ]] && [[ -r "$ACCOUNT_CREDS" ]]; then
    import_env_file "$ACCOUNT_CREDS" "account" || true
else
    stamp "  Credentials: no account-specific config"
fi

# ──────────────────────────────────────────────
# Work cycle loop
# ──────────────────────────────────────────────

# How long to wait between cycles, in seconds
readonly CYCLE_PAUSE="${AGENT_CYCLE_INTERVAL:-300}"

# Retry ceiling and circuit-breaker threshold
readonly PAUSE_CEILING="${AGENT_BACKOFF_MAX:-1800}"      # 30 minutes max
readonly BREAKER_LIMIT="${AGENT_CIRCUIT_BREAKER:-5}"     # halt after N straight failures

# Pass context to the Node.js loop script
export AGENT_USER="$WORKER"
export NODE_PATH="/usr/lib/node_modules"

stamp "Loop active (cycle every ${CYCLE_PAUSE}s, ceiling=${PAUSE_CEILING}s, breaker=${BREAKER_LIMIT})"

streak=0
pause="$CYCLE_PAUSE"

while true; do
    stamp "Cycle begin (streak=$streak, pause=${pause}s)"

    rc=0
    node /usr/local/bin/agent-loop.mjs 2>&1 | tee -a "$WORKER_LOG" || rc=$?

    case "$rc" in
        0)
            # Cycle succeeded — reset everything
            stamp "Cycle finished successfully"
            streak=0
            pause="$CYCLE_PAUSE"
            ;;
        1)
            # Recoverable failure — exponential backoff
            ((streak++)) || true
            stamp "Cycle failed (recoverable, exit=1, streak=$streak)"
            pause=$(( pause * 2 ))
            if (( pause > PAUSE_CEILING )); then
                pause="$PAUSE_CEILING"
            fi
            stamp "Backoff: next pause=${pause}s"
            ;;
        2)
            # Unrecoverable — shut down permanently
            stamp "FATAL: Cycle returned exit=2 (unrecoverable). Halting agent."
            printf 'Agent %s has halted due to an unrecoverable error (exit code 2).\n\nThis typically means an invalid API key or unsupported model.\nInspect logs: journalctl -u agent@%s.service\n\nThe service will not resume until the underlying issue is resolved.\n' \
                "$WORKER" "$WORKER" \
                | mail -s "FATAL: Agent $WORKER halted" root 2>/dev/null || true
            exit 2
            ;;
        3)
            # Timeout — gentler backoff (50% increase)
            ((streak++)) || true
            stamp "Cycle timed out (exit=3, streak=$streak)"
            pause=$(( pause + pause / 2 ))
            if (( pause > PAUSE_CEILING )); then
                pause="$PAUSE_CEILING"
            fi
            ;;
        *)
            # Unrecognised exit code — treat as recoverable
            ((streak++)) || true
            stamp "Cycle failed (unrecognised exit=$rc, streak=$streak)"
            pause=$(( pause * 2 ))
            if (( pause > PAUSE_CEILING )); then
                pause="$PAUSE_CEILING"
            fi
            ;;
    esac

    # Stop when the failure streak is too long
    if (( streak >= BREAKER_LIMIT )); then
        stamp "CIRCUIT BREAKER: $streak consecutive failures. Halting agent."
        printf 'Agent %s was stopped by the circuit breaker after %d consecutive failures.\n\nLast exit code: %d\nInspect logs: journalctl -u agent@%s.service\n\nTo resume: systemctl start agent@%s.service\n' \
            "$WORKER" "$streak" "$rc" "$WORKER" "$WORKER" \
            | mail -s "CIRCUIT BREAKER: Agent $WORKER halted" root 2>/dev/null || true
        exit 1
    fi

    # Sleep until the next cycle, but wake immediately if new mail arrives
    INBOX="$HOME/Maildir/new"
    if command -v inotifywait &>/dev/null && [[ -d "$INBOX" ]]; then
        stamp "Sleeping up to ${pause}s (or until mail arrives)"
        if inotifywait -t "$pause" -e create -e moved_to "$INBOX" 2>/dev/null; then
            stamp "Woken by incoming mail"
        fi
    else
        sleep "$pause"
    fi
done
