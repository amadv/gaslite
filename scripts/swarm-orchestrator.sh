#!/bin/bash
# swarm-orchestrator.sh — DAG-aware coordinator for the agent swarm
#
# Analogous to SwarmKit's Orchestrator: monitors the shared task board,
# spots completed tasks, unlocks downstream work, sends agents ready-task
# notifications, and halts the swarm on critical failures (fail-fast mode).
#
# Runs as a systemd service (swarm-orchestrator.service), polling on a
# configurable interval.
#
# Environment:
#   ORCHESTRATOR_POLL_INTERVAL  — Seconds between board polls (default: 30)
#   ORCHESTRATOR_FAIL_FAST      — Halt all agents when any task fails (default: true)
#
# The orchestrator does not drive agent work cycles — those run on their own
# timers. It only manages the task board and coordinates via mail.

set -euo pipefail

readonly WORKSPACE="/home/shared"
readonly BOARD_FILE="${WORKSPACE}/tasks.jsonl"
readonly EVENT_LOG="${WORKSPACE}/swarm-events.jsonl"
readonly INTERVAL="${ORCHESTRATOR_POLL_INTERVAL:-30}"
readonly HALT_ON_FAILURE="${ORCHESTRATOR_FAIL_FAST:-true}"

report() {
    echo "[$(date -Iseconds)] orchestrator: $*"
}

push_event() {
    local kind="$1"
    local body="${2:-\{\}}"
    local ts
    ts="$(date -Iseconds)"
    local compact
    compact=$(echo "$body" | jq -c . 2>/dev/null || echo "$body")
    jq -cn --arg ts "$ts" --arg src "orchestrator" --arg evt "$kind" \
        --argjson pay "$compact" \
        '{timestamp: $ts, source: $src, event: $evt, payload: $pay}' >> "$EVENT_LOG"
}

# Produce a consolidated view: most recent entry per task ID
snapshot_board() {
    if [[ ! -f "$BOARD_FILE" ]]; then
        echo "[]"
        return
    fi
    jq -s 'group_by(.id) | map(last)' "$BOARD_FILE"
}

# Select tasks that are pending and whose entire blocker set is completed
unblocked_tasks() {
    local board="$1"
    echo "$board" | jq '
        (map({(.id): .status}) | add // {}) as $tbl |
        map(select(
            .status == "pending" and
            ((.blocked_by // []) | all(. as $dep | $tbl[$dep] == "completed"))
        ))
    '
}

# Return IDs of tasks that completed since the last poll
new_completions() {
    local board="$1"
    local seen="${WORKSPACE}/.orchestrator-seen-completed"

    local done_ids
    done_ids=$(echo "$board" | jq -r 'map(select(.status == "completed")) | .[].id')

    local fresh=""
    for tid in $done_ids; do
        if ! grep -qxF "$tid" "$seen" 2>/dev/null; then
            fresh="$fresh $tid"
            echo "$tid" >> "$seen"
        fi
    done
    echo "$fresh"
}

# Return IDs of tasks that entered failure state since the last poll
new_failures() {
    local board="$1"
    local seen="${WORKSPACE}/.orchestrator-seen-failed"

    local failed_ids
    failed_ids=$(echo "$board" | jq -r 'map(select(.status == "failed")) | .[].id')

    local fresh=""
    for tid in $failed_ids; do
        if ! grep -qxF "$tid" "$seen" 2>/dev/null; then
            fresh="$fresh $tid"
            echo "$tid" >> "$seen"
        fi
    done
    echo "$fresh"
}

# Send a mail notification to an agent whose task is now actionable
ping_agent() {
    local target="$1"
    local tid="$2"
    local label="$3"

    printf 'Task ready for you: %s\n\nTask ID: %s\nSubject: %s\n\nRun: task.sh update %s --status in_progress\nThen complete the work and run: task.sh update %s --status completed --result "summary"\n' \
        "$label" "$tid" "$label" "$tid" "$tid" \
        | mail -s "Task ready: $label" "$target" 2>/dev/null || true

    report "Notified $target: task $tid ($label) is ready"
}

# Terminate every agent service (called when fail-fast triggers)
halt_all_agents() {
    local cause="$1"
    report "FAIL-FAST: Stopping all agents — $cause"
    push_event "swarm_halted" "$(jq -n --arg reason "$cause" '{reason: $reason}')"

    local roster
    roster=$(getent group agents 2>/dev/null | cut -d: -f4 | tr ',' ' ')
    for acct in $roster; do
        report "Stopping agent@${acct}.service"
        systemctl stop "agent@${acct}.service" 2>/dev/null || true
    done

    # Broadcast the halt reason to all agents
    printf 'The swarm has been halted.\n\nReason: %s\n\nAll agent services have been stopped. Manual intervention required.\n' \
        "$cause" | mail -s "SWARM HALTED: $cause" all 2>/dev/null || true
}

# True when every task is in a terminal state (completed or failed)
board_finished() {
    local board="$1"
    local active
    active=$(echo "$board" | jq 'map(select(.status == "pending" or .status == "in_progress")) | length')
    [[ "$active" == "0" ]]
}

# --- Main polling loop ---

report "Starting swarm orchestrator (poll=${INTERVAL}s, fail_fast=${HALT_ON_FAILURE})"
push_event "orchestrator_started" "{}"

# Initialise state-tracking files
touch "${WORKSPACE}/.orchestrator-seen-completed"
touch "${WORKSPACE}/.orchestrator-seen-failed"

while true; do
    board=$(snapshot_board)
    n_tasks=$(echo "$board" | jq 'length')

    if [[ "$n_tasks" == "0" ]]; then
        sleep "$INTERVAL"
        continue
    fi

    # Handle newly failed tasks first
    fresh_failures=$(new_failures "$board")
    for tid in $fresh_failures; do
        info=$(echo "$board" | jq -r ".[] | select(.id == \"$tid\")")
        label=$(echo "$info" | jq -r '.subject')
        owner=$(echo "$info" | jq -r '.owner')
        detail=$(echo "$info" | jq -r '.result // "no details"')

        report "Task FAILED: $tid ($label) owner=$owner"
        push_event "task_failed" "$(jq -n --arg id "$tid" --arg subject "$label" --arg owner "$owner" '{id: $id, subject: $subject, owner: $owner}')"

        if [[ "$HALT_ON_FAILURE" == "true" ]]; then
            halt_all_agents "Task $tid ($label) failed: $detail"
            report "Orchestrator exiting due to fail-fast"
            exit 1
        fi
    done

    # Record newly completed tasks
    fresh_done=$(new_completions "$board")
    for tid in $fresh_done; do
        info=$(echo "$board" | jq -r ".[] | select(.id == \"$tid\")")
        label=$(echo "$info" | jq -r '.subject')
        owner=$(echo "$info" | jq -r '.owner')

        report "Task COMPLETED: $tid ($label) by $owner"
        push_event "task_completed" "$(jq -n --arg id "$tid" --arg subject "$label" --arg owner "$owner" '{id: $id, subject: $subject, owner: $owner}')"
    done

    # Notify agents whose tasks just became unblocked
    ready=$(unblocked_tasks "$board")
    n_ready=$(echo "$ready" | jq 'length')

    if [[ "$n_ready" != "0" ]]; then
        echo "$ready" | jq -c '.[]' | while read -r entry; do
            tid=$(echo "$entry" | jq -r '.id')
            owner=$(echo "$entry" | jq -r '.owner')
            label=$(echo "$entry" | jq -r '.subject')

            # Only notify once per task
            notified="${WORKSPACE}/.orchestrator-notified"
            if ! grep -qxF "$tid" "$notified" 2>/dev/null; then
                ping_agent "$owner" "$tid" "$label"
                echo "$tid" >> "$notified"
            fi
        done
    fi

    # Summarise when every task has reached a terminal state
    if board_finished "$board"; then
        n_done=$(echo "$board" | jq 'map(select(.status == "completed")) | length')
        n_fail=$(echo "$board" | jq 'map(select(.status == "failed")) | length')
        report "All tasks terminal: completed=$n_done failed=$n_fail total=$n_tasks"
        push_event "swarm_finished" "$(jq -n --arg completed "$n_done" --arg failed "$n_fail" --arg total "$n_tasks" '{completed: $completed, failed: $failed, total: $total}')"

        if [[ "$n_fail" == "0" ]]; then
            report "Swarm completed successfully"
        else
            report "Swarm completed with failures"
        fi
        # Keep running — new tasks may still be added
    fi

    sleep "$INTERVAL"
done
