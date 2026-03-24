#!/bin/bash
# check-health.sh — Inspect agent liveness via heartbeat files
#
# Agents write a JSON timestamp to ~/.agent-heartbeat on each work cycle.
# This script reads those files and reports which agents are responsive.
#
# Usage:
#   check-health.sh                    Report health for all agents
#   check-health.sh --stale-after 600  Mark agents idle over 600s as stale (default: 900)
#   check-health.sh --json             Emit results as a JSON array
#
# Exit codes:
#   0 — Every agent is healthy
#   1 — At least one agent is unhealthy

set -euo pipefail

# Proxy to the container when invoked from the host side.
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec ${CONTAINER_RUNTIME:-docker} exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

IDLE_LIMIT=900   # seconds before a heartbeat is considered stale
EMIT_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stale-after)
            IDLE_LIMIT="${2:-900}"
            shift 2
            ;;
        --json)
            EMIT_JSON=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

ROSTER=$(getent group agents 2>/dev/null | cut -d: -f4 | tr ',' ' ')

if [[ -z "$ROSTER" ]]; then
    echo "No agents found."
    exit 0
fi

EPOCH_NOW=$(date +%s)
BAD_COUNT=0
JSON_PARTS=""

if [[ "$EMIT_JSON" == "false" ]]; then
    printf "%-16s %-10s %-12s %-8s %-20s %s\n" "AGENT" "SERVICE" "HEARTBEAT" "STALE?" "LAST PHASE" "LAST SEEN"
    printf "%-16s %-10s %-12s %-8s %-20s %s\n" "-----" "-------" "---------" "------" "----------" "---------"
fi

for acct in $ROSTER; do
    HB_PATH="/home/${acct}/.agent-heartbeat"
    SVC="agent@${acct}.service"
    SVC_STATE=$(systemctl is-active "$SVC" 2>/dev/null | head -1) || true
    [[ -z "$SVC_STATE" ]] && SVC_STATE="inactive"

    if [[ ! -f "$HB_PATH" ]]; then
        hb_status="no-heartbeat"
        work_phase="unknown"
        seen_at="never"
        flagged="YES"
        ((BAD_COUNT++)) || true
    else
        hb_raw=$(cat "$HB_PATH" 2>/dev/null || echo '{}')
        hb_ts=$(echo "$hb_raw" | jq -r '.timestamp // ""' 2>/dev/null || echo "")
        work_phase=$(echo "$hb_raw" | jq -r '.phase // "unknown"' 2>/dev/null || echo "unknown")

        if [[ -z "$hb_ts" ]]; then
            hb_status="invalid"
            seen_at="invalid"
            flagged="YES"
            ((BAD_COUNT++)) || true
        else
            # Parse ISO timestamp to Unix epoch
            hb_epoch=$(date -d "$hb_ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${hb_ts%%+*}" +%s 2>/dev/null || echo "0")
            elapsed=$(( EPOCH_NOW - hb_epoch ))
            seen_at="${elapsed}s ago"

            if (( elapsed > IDLE_LIMIT )); then
                hb_status="stale"
                flagged="YES"
                ((BAD_COUNT++)) || true
            else
                hb_status="healthy"
                flagged="no"
            fi
        fi
    fi

    if [[ "$EMIT_JSON" == "true" ]]; then
        row=$(jq -n \
            --arg agent "$acct" \
            --arg service "$SVC_STATE" \
            --arg status "$hb_status" \
            --arg phase "$work_phase" \
            --arg last_seen "$seen_at" \
            --argjson stale "$([ "$flagged" = "YES" ] && echo true || echo false)" \
            '{agent: $agent, service: $service, status: $status, phase: $phase, last_seen: $last_seen, stale: $stale}')
        if [[ -n "$JSON_PARTS" ]]; then
            JSON_PARTS="${JSON_PARTS},${row}"
        else
            JSON_PARTS="$row"
        fi
    else
        printf "%-16s %-10s %-12s %-8s %-20s %s\n" "$acct" "$SVC_STATE" "$hb_status" "$flagged" "$work_phase" "$seen_at"
    fi
done

if [[ "$EMIT_JSON" == "true" ]]; then
    echo "[${JSON_PARTS}]" | jq .
fi

if (( BAD_COUNT > 0 )); then
    if [[ "$EMIT_JSON" == "false" ]]; then
        echo ""
        echo "$BAD_COUNT agent(s) unhealthy (stale threshold: ${IDLE_LIMIT}s)"
    fi
    exit 1
fi

exit 0
