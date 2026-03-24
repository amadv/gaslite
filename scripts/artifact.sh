#!/bin/bash
# artifact.sh — Inter-agent file registry backed by a shared manifest
#
# Agents produce files and record them in a shared manifest so peers can
# discover and consume them. Analogous to SwarmKit's ArtifactStore.
#
# Usage:
#   artifact.sh register <path> [--description <text>]   Record an artifact
#   artifact.sh list [--producer <agent>]                Browse registered artifacts
#   artifact.sh get <path>                               Fetch artifact metadata
#   artifact.sh read <path>                              Print artifact contents
#
# The shared workspace is /home/shared/, writable by the workers group.
# The registry lives at /home/shared/.manifest.jsonl (append-only JSONL).
#
# Examples:
#   artifact.sh register output/report.csv --description "Q4 sales report"
#   artifact.sh list --producer alice
#   artifact.sh read output/report.csv

set -euo pipefail

readonly WORKSPACE="/home/shared"
readonly REGISTRY="${WORKSPACE}/.manifest.jsonl"
readonly HELP="Usage: artifact.sh {register|list|get|read} [options]"

# --- Container check ---
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec ${CONTAINER_RUNTIME:-docker} exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

# Shared workspace must be present before anything else
if [[ ! -d "$WORKSPACE" ]]; then
    echo "Error: Shared workspace $WORKSPACE does not exist." >&2
    echo "It should be created during container build." >&2
    exit 1
fi

# --- Subcommands ---

cmd_register() {
    local relpath="" blurb=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --description)
                blurb="${2:-}"
                shift 2
                ;;
            -*)
                echo "Error: Unknown option '$1'." >&2
                exit 1
                ;;
            *)
                if [[ -z "$relpath" ]]; then
                    relpath="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$relpath" ]]; then
        echo "Error: Path is required." >&2
        echo "Usage: artifact.sh register <path> [--description <text>]" >&2
        exit 1
    fi

    # All paths are relative to the shared workspace
    local abspath="${WORKSPACE}/${relpath}"
    if [[ ! -f "$abspath" ]]; then
        echo "Error: File not found: $abspath" >&2
        exit 1
    fi

    local author bytecount ts
    author="$(whoami)"
    bytecount="$(stat -c %s "$abspath" 2>/dev/null || stat -f %z "$abspath")"
    ts="$(date -Iseconds)"

    # Append a compact JSONL registration record
    jq -cn --arg p "$relpath" --arg pr "$author" --arg d "$blurb" \
        --argjson s "$bytecount" --arg t "$ts" \
        '{path:$p,producer:$pr,description:$d,size_bytes:$s,created_at:$t}' >> "$REGISTRY"

    echo "Registered: $relpath (producer=$author, size=$bytecount bytes)"
}

cmd_list() {
    local filter_by=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --producer)
                filter_by="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ ! -f "$REGISTRY" ]]; then
        echo "No artifacts registered."
        exit 0
    fi

    if [[ -n "$filter_by" ]]; then
        jq -r "select(.producer == \"$filter_by\") | \"\(.created_at)  \(.producer)  \(.path)  \(.description)\"" "$REGISTRY"
    else
        jq -r '"\(.created_at)  \(.producer)  \(.path)  \(.description)"' "$REGISTRY"
    fi
}

cmd_get() {
    local relpath="${1:-}"
    if [[ -z "$relpath" ]]; then
        echo "Error: Path is required." >&2
        echo "Usage: artifact.sh get <path>" >&2
        exit 1
    fi

    if [[ ! -f "$REGISTRY" ]]; then
        echo "No artifacts registered."
        exit 1
    fi

    # Return the most recent registry entry for this path
    jq -c "select(.path == \"$relpath\")" "$REGISTRY" | tail -1
}

cmd_read() {
    local relpath="${1:-}"
    if [[ -z "$relpath" ]]; then
        echo "Error: Path is required." >&2
        echo "Usage: artifact.sh read <path>" >&2
        exit 1
    fi

    local abspath="${WORKSPACE}/${relpath}"
    if [[ ! -f "$abspath" ]]; then
        echo "Error: File not found: $abspath" >&2
        exit 1
    fi

    cat "$abspath"
}

# --- Dispatch ---

ACTION="${1:-}"
shift || true

case "$ACTION" in
    register) cmd_register "$@" ;;
    list)     cmd_list "$@" ;;
    get)      cmd_get "$@" ;;
    read)     cmd_read "$@" ;;
    *)
        echo "$HELP" >&2
        exit 1
        ;;
esac
