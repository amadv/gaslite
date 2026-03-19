#!/bin/bash
# stop-swarm.sh — Halt all agent services and the swarm orchestrator
#
# Usage: stop-swarm.sh [--reason <text>]
#
# Implements cascading cancellation as in SwarmKit: stops every agent
# service and the orchestrator, writing an optional reason to the event log.
#
# Examples:
#   stop-swarm.sh
#   stop-swarm.sh --reason "Critical bug found in task output"

set -euo pipefail

readonly WORKSPACE="/home/shared"
readonly EVENT_LOG="${WORKSPACE}/swarm-events.jsonl"

# --- Container check ---
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec docker exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

# Parse arguments
STOP_REASON="Manual stop requested"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reason)
            STOP_REASON="${2:-Manual stop}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "Stopping swarm: $STOP_REASON"

# Write a halt event to the shared event log
STOP_TS="$(date -Iseconds)"
if [[ -d "$WORKSPACE" ]]; then
    jq -cn --arg ts "$STOP_TS" --arg reason "$STOP_REASON" \
        '{timestamp: $ts, source: "stop-swarm", event: "swarm_halted", payload: {reason: $reason}}' \
        >> "$EVENT_LOG" 2>/dev/null || true
fi

# Bring down the orchestrator first
echo "Stopping swarm-orchestrator.service..."
systemctl stop swarm-orchestrator.service 2>/dev/null || true

# Bring down every agent service
ROSTER=$(getent group agents 2>/dev/null | cut -d: -f4 | tr ',' ' ')
if [[ -z "$ROSTER" ]]; then
    echo "No agents found."
    exit 0
fi

HALTED=0
for acct in $ROSTER; do
    echo "Stopping agent@${acct}.service..."
    if systemctl stop "agent@${acct}.service" 2>/dev/null; then
        ((HALTED++)) || true
    fi
done

# Broadcast a shutdown notice to all agents
printf 'The swarm has been stopped.\n\nReason: %s\nTime: %s\nAgents stopped: %d\n' \
    "$STOP_REASON" "$STOP_TS" "$HALTED" \
    | mail -s "Swarm stopped" all 2>/dev/null || true

echo "Swarm stopped. $HALTED agent(s) halted."
