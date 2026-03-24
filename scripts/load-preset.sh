#!/bin/bash
# load-preset.sh — Instantiate a swarm preset: provision agents, wire task DAG, send kickoff mail
#
# Reads a JSON preset file and translates it into calls to existing primitives:
#   create-agent.sh, task.sh add, send-mail.sh
#
# Usage:
#   load-preset.sh <file> [--dry-run] [--skip-existing]
#
# Options:
#   --dry-run         Show commands without running them
#   --skip-existing   Skip over agents that are already provisioned (safe for re-runs)
#
# Environment variables in the preset (${VAR} or ${VAR:-default}) are expanded
# using bash parameter expansion before parsing. Supply them as env vars:
#   TOPIC="AI Agents" load-preset.sh presets/content-pipeline.json
#
# Examples:
#   load-preset.sh presets/content-pipeline.json
#   load-preset.sh presets/content-pipeline.json --dry-run
#   load-preset.sh presets/codebase-audit.json --skip-existing

set -euo pipefail

readonly HELP_TEXT="Usage: load-preset.sh <file> [--dry-run] [--skip-existing] [--check-vars]"

# --- Environment check ---
# When called from the host, copy the preset into the container and re-invoke there.
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    MANIFEST="${1:-}"
    if [[ -z "$MANIFEST" ]]; then
        echo "Error: A preset file path is required." >&2
        echo "$HELP_TEXT" >&2
        exit 1
    fi
    if [[ ! -f "$MANIFEST" ]]; then
        echo "Error: Preset file not found: $MANIFEST" >&2
        exit 1
    fi
    # Stream the preset into the container (docker cp is blocked by systemd's tmpfs on /tmp)
    STAGING="/tmp/preset-$$.json"
    ${CONTAINER_RUNTIME:-docker} exec -i "$CONTAINER" tee "$STAGING" > /dev/null < "$MANIFEST"
    shift
    # Collect environment variables to forward for expansion
    FORWARD_ENV=()
    while IFS='=' read -r envkey envval; do
        [[ -z "$envkey" ]] && continue
        FORWARD_ENV+=(-e "$envkey=$envval")
    done < <(env | grep -v '^_=' | grep -v '^SHLVL=' | grep -v '^PWD=' || true)
    ${CONTAINER_RUNTIME:-docker} exec "${FORWARD_ENV[@]}" "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$STAGING" "$@"
    RC=$?
    ${CONTAINER_RUNTIME:-docker} exec "$CONTAINER" rm -f "$STAGING"
    exit $RC
fi

# --- Parse arguments ---
MANIFEST=""
PREVIEW=false
KEEP_EXISTING=false
REPORT_VARS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)       PREVIEW=true; shift ;;
        --skip-existing) KEEP_EXISTING=true; shift ;;
        --check-vars)    REPORT_VARS=true; shift ;;
        -*)
            echo "Error: Unknown flag '$1'." >&2
            echo "$HELP_TEXT" >&2
            exit 1
            ;;
        *)
            if [[ -z "$MANIFEST" ]]; then
                MANIFEST="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$MANIFEST" ]]; then
    echo "Error: A preset file path is required." >&2
    echo "$HELP_TEXT" >&2
    exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
    echo "Error: File not found: $MANIFEST" >&2
    exit 1
fi

# --- Phase 1: VALIDATE ---

echo "=== Phase 1: Validate ==="

# Read the raw preset content for variable scanning and expansion
RAW_CONTENT=$(cat "$MANIFEST")

# Scan for ${VAR} and ${VAR:-default} patterns in the preset file
declare -A FOUND_DEFAULTS=()
declare -a FOUND_NAMES=()
while IFS= read -r expr; do
    [[ -z "$expr" ]] && continue
    VNAME="${expr%%:-*}"
    if [[ "$expr" == *":-"* ]]; then
        VDEFAULT="${expr#*:-}"
    else
        VDEFAULT=""
    fi
    if [[ -z "${FOUND_DEFAULTS[$VNAME]+isset}" ]]; then
        FOUND_NAMES+=("$VNAME")
        FOUND_DEFAULTS[$VNAME]="$VDEFAULT"
    fi
done < <(grep -oP '\$\{\K[A-Z_][A-Z0-9_]*(?::-[^}]*)?' "$MANIFEST")

# With --check-vars, report variable status and exit
if [[ "$REPORT_VARS" == "true" ]]; then
    for VNAME in "${FOUND_NAMES[@]}"; do
        VDEFAULT="${FOUND_DEFAULTS[$VNAME]}"
        VCURRENT="${!VNAME:-}"
        if [[ -n "$VCURRENT" ]]; then
            echo "  $VNAME=$VCURRENT (set)"
        elif [[ -n "$VDEFAULT" ]]; then
            echo "  $VNAME (default: $VDEFAULT)"
        else
            echo "  $VNAME (required, no default)"
        fi
    done
    exit 0
fi

# Check for required but unset variables
ABSENT_VARS=()
for VNAME in "${FOUND_NAMES[@]}"; do
    VDEFAULT="${FOUND_DEFAULTS[$VNAME]}"
    VCURRENT="${!VNAME:-}"
    if [[ -z "$VCURRENT" && -z "$VDEFAULT" ]]; then
        ABSENT_VARS+=("$VNAME")
    elif [[ -z "$VCURRENT" && -n "$VDEFAULT" ]]; then
        echo "  -> $VNAME not set, falling back to default: $VDEFAULT"
    fi
done

if [[ ${#ABSENT_VARS[@]} -gt 0 ]]; then
    echo "Error: The following variables are required but have no value or default:" >&2
    for v in "${ABSENT_VARS[@]}"; do
        echo "  $v" >&2
    done
    echo "" >&2
    echo "Set them before running:" >&2
    echo "  ${ABSENT_VARS[*]}=<value> load-preset.sh $MANIFEST" >&2
    exit 1
fi

# Expand environment variables when the preset contains ${...} references
if echo "$RAW_CONTENT" | grep -q '${'; then
    EXPANDED=$(eval "cat <<__PRESET_EOF__
$RAW_CONTENT
__PRESET_EOF__
")
    echo "  -> Environment variables expanded"
else
    EXPANDED="$RAW_CONTENT"
fi

# Confirm the result is valid JSON
if ! echo "$EXPANDED" | jq empty 2>/dev/null; then
    echo "Error: The preset at $MANIFEST does not contain valid JSON" >&2
    exit 1
fi

# Verify required top-level fields
SWARM_NAME=$(echo "$EXPANDED" | jq -r '.name // empty')
if [[ -z "$SWARM_NAME" ]]; then
    echo "Error: Preset is missing required field 'name'." >&2
    exit 1
fi

WORKER_COUNT=$(echo "$EXPANDED" | jq '.agents | length')
if [[ "$WORKER_COUNT" -eq 0 ]]; then
    echo "Error: Preset must include at least one agent." >&2
    exit 1
fi

WORK_COUNT=$(echo "$EXPANDED" | jq '.tasks | length')
if [[ "$WORK_COUNT" -eq 0 ]]; then
    echo "Error: Preset must include at least one task." >&2
    exit 1
fi

# Gather declared names and task IDs for cross-reference checks
WORKER_NAMES=$(echo "$EXPANDED" | jq -r '.agents[].name')
WORK_IDS=$(echo "$EXPANDED" | jq -r '.tasks[].id')

# Each task's owner must be a declared agent
while IFS= read -r holder; do
    if ! echo "$WORKER_NAMES" | grep -qx "$holder"; then
        echo "Error: Task owner '$holder' is not a declared agent." >&2
        exit 1
    fi
done < <(echo "$EXPANDED" | jq -r '.tasks[].owner')

# Every blocked_by reference must point to a real task ID
while IFS= read -r prereq; do
    [[ -z "$prereq" || "$prereq" == "null" ]] && continue
    if ! echo "$WORK_IDS" | grep -qx "$prereq"; then
        echo "Error: blocked_by references unknown task '$prereq'." >&2
        exit 1
    fi
done < <(echo "$EXPANDED" | jq -r '.tasks[].blocked_by[]? // empty')

# Topological sort — iterative Kahn-style, detects cycles
declare -a SORTED_IDS=()
declare -A VISITED=()

ALL_IDS=()
while IFS= read -r wid; do
    ALL_IDS+=("$wid")
done < <(echo "$WORK_IDS")

BOUND=${#ALL_IDS[@]}
for (( round=0; round<=BOUND; round++ )); do
    if [[ ${#SORTED_IDS[@]} -eq ${#ALL_IDS[@]} ]]; then
        break
    fi
    MADE_PROGRESS=false
    for wid in "${ALL_IDS[@]}"; do
        [[ -n "${VISITED[$wid]:-}" ]] && continue
        PREREQS_DONE=true
        while IFS= read -r prereq; do
            [[ -z "$prereq" || "$prereq" == "null" ]] && continue
            if [[ -z "${VISITED[$prereq]:-}" ]]; then
                PREREQS_DONE=false
                break
            fi
        done < <(echo "$EXPANDED" | jq -r --arg id "$wid" '.tasks[] | select(.id == $id) | .blocked_by[]? // empty')
        if [[ "$PREREQS_DONE" == "true" ]]; then
            SORTED_IDS+=("$wid")
            VISITED[$wid]=1
            MADE_PROGRESS=true
        fi
    done
    if [[ "$MADE_PROGRESS" == "false" && ${#SORTED_IDS[@]} -lt ${#ALL_IDS[@]} ]]; then
        echo "Error: Circular dependency detected in task graph." >&2
        echo "  Resolved: ${SORTED_IDS[*]}" >&2
        echo "  Unresolvable:" >&2
        for wid in "${ALL_IDS[@]}"; do
            [[ -z "${VISITED[$wid]:-}" ]] && echo "    $wid" >&2
        done
        exit 1
    fi
done

echo "  -> Swarm '$SWARM_NAME': $WORKER_COUNT agents, $WORK_COUNT tasks"
echo "  -> Execution order: ${SORTED_IDS[*]}"
echo "  -> Validation complete"

if [[ "$PREVIEW" == "true" ]]; then
    echo ""
    echo "=== DRY RUN — commands that would be executed ==="
    echo ""

    echo "# Phase 2: Provision agents"
    for i in $(seq 0 $((WORKER_COUNT - 1))); do
        ANAME=$(echo "$EXPANDED" | jq -r ".agents[$i].name")
        AROLE=$(echo "$EXPANDED" | jq -r ".agents[$i].persona // empty")
        AINSTR=$(echo "$EXPANDED" | jq -r ".agents[$i].instructions // empty")
        CMD="create-agent.sh $ANAME"
        [[ -n "$AROLE" ]] && CMD="$CMD --persona $AROLE"
        [[ -n "$AINSTR" ]] && CMD="$CMD --instructions \"$AINSTR\""
        echo "  $CMD"
    done

    echo ""
    echo "# Phase 3: Register tasks (dependency order)"
    for wid in "${SORTED_IDS[@]}"; do
        TASK_DATA=$(echo "$EXPANDED" | jq -c --arg id "$wid" '.tasks[] | select(.id == $id)')
        TSUBJ=$(echo "$TASK_DATA" | jq -r '.subject')
        TOWNER=$(echo "$TASK_DATA" | jq -r '.owner')
        TDESC=$(echo "$TASK_DATA" | jq -r '.description // empty')
        TDEPS=$(echo "$TASK_DATA" | jq -r '.blocked_by // [] | join(",")')
        CMD="task.sh add \"$TSUBJ\" --owner $TOWNER"
        [[ -n "$TDESC" ]] && CMD="$CMD --description \"$TDESC\""
        [[ -n "$TDEPS" ]] && CMD="$CMD --blocked-by <resolved:$TDEPS>"
        echo "  $CMD  # id=$wid"
    done

    MAIL_TOTAL=$(echo "$EXPANDED" | jq '.mail // [] | length')
    if [[ "$MAIL_TOTAL" -gt 0 ]]; then
        echo ""
        echo "# Phase 4: Dispatch kickoff mail"
        for i in $(seq 0 $((MAIL_TOTAL - 1))); do
            MRECIP=$(echo "$EXPANDED" | jq -r ".mail[$i].to")
            MSUBJ=$(echo "$EXPANDED" | jq -r ".mail[$i].subject // \"Preset loaded\"")
            MBODY=$(echo "$EXPANDED" | jq -r ".mail[$i].body // \"\"")
            echo "  send-mail.sh $MRECIP --subject \"$MSUBJ\" -- \"$MBODY\""
        done
    fi

    echo ""
    echo "=== End dry run ==="
    exit 0
fi

# --- Phase 2: PROVISION AGENTS ---

echo ""
echo "=== Phase 2: Create agents ==="

for i in $(seq 0 $((WORKER_COUNT - 1))); do
    ANAME=$(echo "$EXPANDED" | jq -r ".agents[$i].name")
    AROLE=$(echo "$EXPANDED" | jq -r ".agents[$i].persona // empty")
    AINSTR=$(echo "$EXPANDED" | jq -r ".agents[$i].instructions // empty")

    if [[ "$KEEP_EXISTING" == "true" ]] && id "$ANAME" &>/dev/null; then
        echo "  -> Skipping $ANAME (already provisioned)"
        continue
    fi

    CREATE_ARGS=("$ANAME")
    [[ -n "$AROLE" ]] && CREATE_ARGS+=(--persona "$AROLE")
    [[ -n "$AINSTR" ]] && CREATE_ARGS+=(--instructions "$AINSTR")

    echo "  -> Provisioning: $ANAME${AROLE:+ (role=$AROLE)}"
    /usr/local/bin/create-agent.sh "${CREATE_ARGS[@]}"
done

# --- Phase 3: REGISTER TASKS (dependency order) ---

echo ""
echo "=== Phase 3: Create tasks ==="

declare -A REAL_ID_MAP=()   # symbolic ID -> assigned real task ID

for wid in "${SORTED_IDS[@]}"; do
    TASK_DATA=$(echo "$EXPANDED" | jq -c --arg id "$wid" '.tasks[] | select(.id == $id)')
    TSUBJ=$(echo "$TASK_DATA" | jq -r '.subject')
    TOWNER=$(echo "$TASK_DATA" | jq -r '.owner')
    TDESC=$(echo "$TASK_DATA" | jq -r '.description // empty')
    DEPS_LIST=$(echo "$TASK_DATA" | jq -r '.blocked_by // []')

    TASK_ARGS=("$TSUBJ" --owner "$TOWNER")
    [[ -n "$TDESC" ]] && TASK_ARGS+=(--description "$TDESC")

    # Translate symbolic dependency IDs to real assigned IDs
    DEP_COUNT=$(echo "$DEPS_LIST" | jq 'length')
    if [[ "$DEP_COUNT" -gt 0 ]]; then
        RESOLVED=()
        while IFS= read -r dep; do
            MAPPED="${REAL_ID_MAP[$dep]:-}"
            if [[ -z "$MAPPED" ]]; then
                echo "Error: Cannot resolve dependency '$dep' for task '$wid'." >&2
                exit 1
            fi
            RESOLVED+=("$MAPPED")
        done < <(echo "$DEPS_LIST" | jq -r '.[]')
        JOINED=$(IFS=','; echo "${RESOLVED[*]}")
        TASK_ARGS+=(--blocked-by "$JOINED")
    fi

    ASSIGNED=$(/usr/local/bin/task.sh add "${TASK_ARGS[@]}")
    REAL_ID_MAP[$wid]="$ASSIGNED"
    echo "  -> $wid => $ASSIGNED: $TSUBJ (owner=$TOWNER)"
done

# --- Phase 4: DISPATCH KICKOFF MAIL (best-effort) ---

MAIL_TOTAL=$(echo "$EXPANDED" | jq '.mail // [] | length')
if [[ "$MAIL_TOTAL" -gt 0 ]]; then
    echo ""
    echo "=== Phase 4: Send kickoff mail ==="

    for i in $(seq 0 $((MAIL_TOTAL - 1))); do
        MRECIP=$(echo "$EXPANDED" | jq -r ".mail[$i].to")
        MSUBJ=$(echo "$EXPANDED" | jq -r ".mail[$i].subject // \"Preset loaded\"")
        MBODY=$(echo "$EXPANDED" | jq -r ".mail[$i].body // \"\"")

        echo "  -> Sending to $MRECIP: $MSUBJ"
        /usr/local/bin/send-mail.sh "$MRECIP" --subject "$MSUBJ" -- "$MBODY" || {
            echo "  Warning: Failed to deliver mail to $MRECIP (continuing)" >&2
        }
    done
fi

# --- Phase 5: PERSIST STATE ---

echo ""
echo "=== Phase 5: Save state ==="

# Serialise the symbolic->real ID mapping as JSON
MAPPING_JSON="{"
IS_FIRST=true
for wid in "${SORTED_IDS[@]}"; do
    [[ "$IS_FIRST" == "true" ]] && IS_FIRST=false || MAPPING_JSON+=","
    MAPPING_JSON+="\"$wid\":\"${REAL_ID_MAP[$wid]}\""
done
MAPPING_JSON+="}"

# Build the agent list as a JSON array
WORKERS_JSON=$(echo "$WORKER_NAMES" | jq -R . | jq -s .)

# Commit state to a shared file for downstream tooling
STATE_PATH="/home/shared/.preset-state.json"
jq -n \
    --arg preset "$SWARM_NAME" \
    --arg loaded_at "$(date -Iseconds)" \
    --argjson id_map "$MAPPING_JSON" \
    --argjson agents "$WORKERS_JSON" \
    '{preset: $preset, loaded_at: $loaded_at, id_map: $id_map, agents: $agents}' \
    > "$STATE_PATH"

echo "  -> State written to $STATE_PATH"
echo ""
echo "=== Swarm '$SWARM_NAME' is live ==="
echo "  Agents: $WORKER_COUNT"
echo "  Tasks:  $WORK_COUNT"
echo "  Mail:   $MAIL_TOTAL"
echo ""
echo "  View task graph:  task.sh graph"
echo "  View swarm status: swarm-status.sh"
