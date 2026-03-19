#!/bin/bash
# swarm-status.sh — Combined swarm health and progress overview
#
# Analogous to SwarmKit's SwarmResult: surfaces task board state, agent
# health, accumulated costs, and recent event history in a single view.
#
# Usage:
#   swarm-status.sh                  Full status overview
#   swarm-status.sh --tasks          Task board summary only
#   swarm-status.sh --costs          Cost aggregation only
#   swarm-status.sh --events [N]     Last N swarm events (default: 20)
#   swarm-status.sh --json           Output everything as JSON

set -euo pipefail

readonly WORKSPACE="/home/shared"
readonly BOARD_FILE="${WORKSPACE}/tasks.jsonl"
readonly EVENT_LOG="${WORKSPACE}/swarm-events.jsonl"

# --- Container check ---
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec docker exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

# Argument parsing
DISPLAY_MODE="full"
N_EVENTS=20
AS_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tasks)  DISPLAY_MODE="tasks";  shift ;;
        --costs)  DISPLAY_MODE="costs";  shift ;;
        --events) DISPLAY_MODE="events"; N_EVENTS="${2:-20}"; shift; shift 2>/dev/null || true ;;
        --json)   AS_JSON=true; shift ;;
        *)        shift ;;
    esac
done

# --- Task board section ---
section_tasks() {
    if [[ ! -f "$BOARD_FILE" ]]; then
        echo "Task Board: No tasks"
        return
    fi

    local board
    board=$(jq -s 'group_by(.id) | map(last)' "$BOARD_FILE")
    local n_total n_pending n_active n_done n_fail
    n_total=$(echo "$board" | jq 'length')
    n_pending=$(echo "$board" | jq 'map(select(.status == "pending")) | length')
    n_active=$(echo "$board" | jq 'map(select(.status == "in_progress")) | length')
    n_done=$(echo "$board" | jq 'map(select(.status == "completed")) | length')
    n_fail=$(echo "$board" | jq 'map(select(.status == "failed")) | length')

    if [[ "$AS_JSON" == "true" ]]; then
        jq -n --argjson total "$n_total" --argjson pending "$n_pending" \
            --argjson in_progress "$n_active" --argjson completed "$n_done" \
            --argjson failed "$n_fail" \
            '{total: $total, pending: $pending, in_progress: $in_progress, completed: $completed, failed: $failed}'
        return
    fi

    echo "=== Task Board ==="
    echo "  Total:       $n_total"
    echo "  Pending:     $n_pending"
    echo "  In Progress: $n_active"
    echo "  Completed:   $n_done"
    echo "  Failed:      $n_fail"

    # Interpret overall run state
    if (( n_total > 0 )) && (( n_pending == 0 )) && (( n_active == 0 )); then
        if (( n_fail == 0 )); then
            echo "  Result:      SUCCESS (all tasks completed)"
        else
            echo "  Result:      PARTIAL ($n_fail task(s) failed)"
        fi
    elif (( n_total > 0 )); then
        echo "  Result:      IN PROGRESS"
    fi
    echo ""

    if (( n_active > 0 )); then
        echo "  Active tasks:"
        echo "$board" | jq -r 'map(select(.status == "in_progress")) | .[] | "    \(.id)  \(.owner)  \(.subject)"'
        echo ""
    fi
}

# --- Cost aggregation section ---
section_costs() {
    local grand_cost=0
    local grand_cycles=0
    local grand_turns=0

    ROSTER=$(getent group agents 2>/dev/null | cut -d: -f4 | tr ',' ' ')

    if [[ -z "$ROSTER" ]]; then
        echo "No agents found."
        return
    fi

    if [[ "$AS_JSON" == "false" ]]; then
        echo "=== Cost Summary ==="
        printf "  %-16s %8s %8s %10s\n" "AGENT" "CYCLES" "TURNS" "COST (USD)"
        printf "  %-16s %8s %8s %10s\n" "-----" "------" "-----" "----------"
    fi

    local row_entries=""

    for acct in $ROSTER; do
        local results_dir="/home/${acct}/.agent-results"
        local acct_cost=0 acct_cycles=0 acct_turns=0

        if [[ -d "$results_dir" ]]; then
            for rfile in "$results_dir"/cycle-*.json; do
                [[ -f "$rfile" ]] || continue
                ((acct_cycles++)) || true

                local c t
                c=$(jq -r '.cost_usd // 0' "$rfile" 2>/dev/null || echo 0)
                t=$(jq -r '.turns // 0' "$rfile" 2>/dev/null || echo 0)

                acct_cost=$(awk "BEGIN {printf \"%.4f\", $acct_cost + $c}")
                acct_turns=$(( acct_turns + t ))
            done
        fi

        grand_cost=$(awk "BEGIN {printf \"%.4f\", $grand_cost + $acct_cost}")
        grand_cycles=$(( grand_cycles + acct_cycles ))
        grand_turns=$(( grand_turns + acct_turns ))

        if [[ "$AS_JSON" == "true" ]]; then
            row=$(jq -n --arg agent "$acct" --argjson cycles "$acct_cycles" \
                --argjson turns "$acct_turns" --arg cost "$acct_cost" \
                '{agent: $agent, cycles: $cycles, turns: $turns, cost_usd: ($cost | tonumber)}')
            if [[ -n "$row_entries" ]]; then
                row_entries="${row_entries},${row}"
            else
                row_entries="$row"
            fi
        else
            printf "  %-16s %8d %8d %10s\n" "$acct" "$acct_cycles" "$acct_turns" "\$$acct_cost"
        fi
    done

    if [[ "$AS_JSON" == "true" ]]; then
        jq -n --arg total_cost "$grand_cost" --argjson total_cycles "$grand_cycles" \
            --argjson total_turns "$grand_turns" --argjson agents "[$row_entries]" \
            '{total_cost_usd: ($total_cost | tonumber), total_cycles: $total_cycles, total_turns: $total_turns, agents: $agents}'
    else
        printf "  %-16s %8s %8s %10s\n" "-----" "------" "-----" "----------"
        printf "  %-16s %8d %8d %10s\n" "TOTAL" "$grand_cycles" "$grand_turns" "\$$grand_cost"
        echo ""
    fi
}

# --- Events section ---
section_events() {
    local limit="$1"

    # Merge swarm-level events with per-agent event logs, sort by timestamp
    {
        if [[ -f "$EVENT_LOG" ]]; then
            cat "$EVENT_LOG"
        fi

        ROSTER=$(getent group agents 2>/dev/null | cut -d: -f4 | tr ',' ' ')
        for acct in $ROSTER; do
            local alog="/home/${acct}/.agent-events.jsonl"
            if [[ -f "$alog" ]]; then
                cat "$alog"
            fi
        done
    } | jq -s 'sort_by(.timestamp) | .[-'"$limit"':]' 2>/dev/null | {
        if [[ "$AS_JSON" == "true" ]]; then
            cat
        else
            echo "=== Recent Events (last $limit) ==="
            jq -r '.[] | "  \(.timestamp)  \(.agent // .source)  \(.event)  \(del(.timestamp, .agent, .source, .event) | to_entries | map("\(.key)=\(.value)") | join(" "))"' 2>/dev/null || echo "  No events."
            echo ""
        fi
    }
}

# --- Agent health section ---
section_health() {
    if [[ "$AS_JSON" == "true" ]]; then
        /usr/local/bin/check-health.sh --json 2>/dev/null || true
    else
        echo "=== Agent Health ==="
        /usr/local/bin/check-health.sh 2>/dev/null | sed 's/^/  /' || true
        echo ""
    fi
}

# --- Route to requested section ---

case "$DISPLAY_MODE" in
    tasks)
        section_tasks
        ;;
    costs)
        section_costs
        ;;
    events)
        section_events "$N_EVENTS"
        ;;
    full)
        if [[ "$AS_JSON" == "true" ]]; then
            t=$(section_tasks)
            c=$(section_costs)
            e=$(section_events "$N_EVENTS")
            h=$(section_health)
            jq -n \
                --argjson tasks "$t" \
                --argjson costs "$c" \
                --argjson events "$e" \
                --argjson health "$h" \
                '{tasks: $tasks, costs: $costs, events: $events, health: $health}'
        else
            section_tasks
            section_health
            section_costs
            section_events "$N_EVENTS"
        fi
        ;;
esac
