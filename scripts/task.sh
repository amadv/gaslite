#!/bin/bash
# task.sh — Shared task board with DAG dependency tracking
#
# Maintains an append-only task log at /home/shared/tasks.jsonl supporting
# SwarmKit-style blocked_by relationships between tasks.
#
# Usage:
#   task.sh add <subject> --owner <agent> [--description <text>] [--blocked-by <task-id>,...]
#   task.sh list [--owner <agent>] [--status <status>]
#   task.sh ready [--owner <agent>]         Show tasks whose blockers are all done
#   task.sh update <task-id> --status <pending|in_progress|completed|failed> [--result <text>]
#   task.sh get <task-id>                   Show full task detail
#   task.sh graph                           Print dependency graph
#
# Valid statuses: pending, in_progress, completed, failed
# A task is "ready" when status=pending and every blocked_by entry is completed.
#
# Examples:
#   task.sh add "Build engine" --owner alice --description "Core game engine"
#   task.sh add "Build snake" --owner bob --blocked-by task-a1b2
#   task.sh update task-a1b2 --status completed --result "Engine built at /home/shared/engine/"
#   task.sh ready --owner bob

set -euo pipefail

readonly WORKSPACE="/home/shared"
readonly BOARD="${WORKSPACE}/tasks.jsonl"
readonly HELP="Usage: task.sh {add|list|ready|update|get|graph} [options]"

# --- Container check ---
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec ${CONTAINER_RUNTIME:-docker} exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

# The shared workspace must already exist
if [[ ! -d "$WORKSPACE" ]]; then
    echo "Error: Shared workspace $WORKSPACE does not exist." >&2
    exit 1
fi

# Produce a random 8-hex-char task identifier
make_id() {
    printf "task-%s" "$(head -c 4 /dev/urandom | xxd -p)"
}

# Retrieve the most recent board entry for a given task ID
# (The board is append-only; the last record wins.)
fetch_task() {
    local tid="$1"
    if [[ ! -f "$BOARD" ]]; then
        return 1
    fi
    local hit
    hit=$(jq -c "select(.id == \"$tid\")" "$BOARD" | tail -1)
    if [[ -z "$hit" ]]; then
        return 1
    fi
    echo "$hit"
}

# Return the status field of a task by ID
fetch_status() {
    local tid="$1"
    local rec
    rec="$(fetch_task "$tid")" || return 1
    echo "$rec" | jq -r '.status'
}

# Build a deduplicated board view (last entry per ID, as newline-separated JSON)
all_current() {
    if [[ ! -f "$BOARD" ]]; then
        return 0
    fi
    jq -s 'group_by(.id) | map(last)[]' "$BOARD"
}

# --- Subcommands ---

cmd_add() {
    local title="" assignee="" notes="" deps=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner)
                assignee="${2:-}"
                shift 2
                ;;
            --description)
                notes="${2:-}"
                shift 2
                ;;
            --blocked-by)
                deps="${2:-}"
                shift 2
                ;;
            -*)
                echo "Error: Unknown option '$1'." >&2
                exit 1
                ;;
            *)
                if [[ -z "$title" ]]; then
                    title="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$title" ]]; then
        echo "Error: Subject is required." >&2
        echo "Usage: task.sh add <subject> --owner <agent> [--description <text>] [--blocked-by <id>,...]" >&2
        exit 1
    fi

    if [[ -z "$assignee" ]]; then
        echo "Error: --owner is required." >&2
        exit 1
    fi

    local tid ts
    tid="$(make_id)"
    ts="$(date -Iseconds)"

    # Convert comma-separated dependency list into a JSON array
    local deps_json="[]"
    if [[ -n "$deps" ]]; then
        deps_json=$(echo "$deps" | tr ',' '\n' | jq -R . | jq -s .)
        for dep in $(echo "$deps" | tr ',' ' '); do
            if ! fetch_task "$dep" &>/dev/null; then
                echo "Warning: Blocker task '$dep' not found in task board." >&2
            fi
        done
    fi

    # Append a new compact JSONL record
    jq -cn \
        --arg id "$tid" \
        --arg subject "$title" \
        --arg description "$notes" \
        --arg owner "$assignee" \
        --arg status "pending" \
        --argjson blocked_by "$deps_json" \
        --arg created_at "$ts" \
        --arg updated_at "$ts" \
        --arg result "" \
        '{id: $id, subject: $subject, description: $description, owner: $owner, status: $status, blocked_by: $blocked_by, created_at: $created_at, updated_at: $updated_at, result: $result}' \
        >> "$BOARD"

    echo "$tid"
}

cmd_list() {
    local by_owner="" by_status=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner)  by_owner="${2:-}";  shift 2 ;;
            --status) by_status="${2:-}"; shift 2 ;;
            *)        shift ;;
        esac
    done

    if [[ ! -f "$BOARD" ]]; then
        echo "No tasks."
        exit 0
    fi

    local cond="true"
    [[ -n "$by_owner" ]]  && cond="$cond and .owner == \"$by_owner\""
    [[ -n "$by_status" ]] && cond="$cond and .status == \"$by_status\""

    jq -s "group_by(.id) | map(last) | map(select($cond))[] | \"\(.id)  \(.status | (if length < 12 then . + (\" \" * (12 - length)) else . end))  \(.owner | (if length < 12 then . + (\" \" * (12 - length)) else . end))  \(.subject)\"" "$BOARD" | sed 's/^"//;s/"$//'
}

cmd_ready() {
    local by_owner=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner) by_owner="${2:-}"; shift 2 ;;
            *)       shift ;;
        esac
    done

    if [[ ! -f "$BOARD" ]]; then
        echo "No tasks."
        exit 0
    fi

    local board
    board=$(jq -s 'group_by(.id) | map(last)' "$BOARD")

    # Emit tasks that are pending and fully unblocked
    echo "$board" | jq -r --arg owner "$by_owner" '
        (map({(.id): .status}) | add // {}) as $tbl |
        .[] |
        select(.status == "pending") |
        select(if $owner != "" then .owner == $owner else true end) |
        select(
            (.blocked_by // []) | all(. as $dep | $tbl[$dep] == "completed")
        ) |
        "\(.id)  \(.owner)  \(.subject)"
    '
}

cmd_update() {
    local tid="" new_status="" new_result=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status) new_status="${2:-}"; shift 2 ;;
            --result) new_result="${2:-}"; shift 2 ;;
            -*)
                echo "Error: Unknown option '$1'." >&2
                exit 1
                ;;
            *)
                if [[ -z "$tid" ]]; then
                    tid="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$tid" ]]; then
        echo "Error: Task ID is required." >&2
        exit 1
    fi

    # Validate the status value if one was provided
    if [[ -n "$new_status" ]]; then
        case "$new_status" in
            pending|in_progress|completed|failed) ;;
            *)
                echo "Error: Invalid status '$new_status'. Must be: pending, in_progress, completed, failed." >&2
                exit 1
                ;;
        esac
    fi

    local current
    current="$(fetch_task "$tid")" || {
        echo "Error: Task '$tid' not found." >&2
        exit 1
    }

    local ts
    ts="$(date -Iseconds)"

    # Merge the update into the existing record and append as a new entry
    echo "$current" | jq -c \
        --arg status "${new_status:-}" \
        --arg result "${new_result:-}" \
        --arg updated_at "$ts" \
        '. + {updated_at: $updated_at} + (if $status != "" then {status: $status} else {} end) + (if $result != "" then {result: $result} else {} end)' \
        >> "$BOARD"

    echo "Updated $tid: status=${new_status:-unchanged}"
}

cmd_get() {
    local tid="${1:-}"
    if [[ -z "$tid" ]]; then
        echo "Error: Task ID is required." >&2
        exit 1
    fi

    local current
    current="$(fetch_task "$tid")" || {
        echo "Error: Task '$tid' not found." >&2
        exit 1
    }

    echo "$current" | jq .
}

cmd_graph() {
    if [[ ! -f "$BOARD" ]]; then
        echo "No tasks."
        exit 0
    fi

    # Render a text-based dependency edge list
    jq -s 'group_by(.id) | map(last)' "$BOARD" | jq -r '
        .[] |
        . as $t |
        if (.blocked_by | length) > 0 then
            .blocked_by[] | "\(.) -> \($t.id)  (\($t.subject))"
        else
            "\($t.id)  \($t.subject) [no dependencies]"
        end
    '
}

# --- Dispatch ---

ACTION="${1:-}"
shift || true

case "$ACTION" in
    add)    cmd_add "$@" ;;
    list)   cmd_list "$@" ;;
    ready)  cmd_ready "$@" ;;
    update) cmd_update "$@" ;;
    get)    cmd_get "$@" ;;
    graph)  cmd_graph "$@" ;;
    *)
        echo "$HELP" >&2
        exit 1
        ;;
esac
