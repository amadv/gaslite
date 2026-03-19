#!/bin/bash
# snapshot-agents.sh — Point-in-time backup of agent state via a dedicated git repo
#
# Runs on the HOST only. Uses a separate GIT_DIR (.agent-snapshots) so that
# snapshots never pollute the project's own git history. The snapshot directory
# is not bind-mounted into the container, so agents cannot access it.
#
# Usage: snapshot-agents.sh <command> [args]
#
# Commands:
#   init              Set up the snapshot repository
#   create [message]  Record a new snapshot (default message: timestamp)
#   log [git-args]    Browse snapshot history
#   diff [git-args]   Show what changed since the last snapshot
#   show [git-args]   Inspect a specific snapshot
#   status            Summarize pending changes
#   help              Print this usage text

set -euo pipefail

# Snapshots are host-only — bail out if we detect a container environment
if [[ -f /.dockerenv ]]; then
    echo "Error: snapshot-agents.sh must run on the host, not inside the container." >&2
    exit 1
fi

# Locate the project root whether invoked from scripts/ or the root directly
INVOCATION_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(basename "$INVOCATION_DIR")" == "scripts" ]]; then
    ROOT_DIR="$(cd "$INVOCATION_DIR/.." && pwd)"
else
    ROOT_DIR="$INVOCATION_DIR"
fi

readonly SNAP_REPO="$ROOT_DIR/.agent-snapshots"
readonly SNAP_WORKTREE="$ROOT_DIR"

# Run git commands against the snapshot repo rather than the project repo
snap_git() {
    git --git-dir="$SNAP_REPO" --work-tree="$SNAP_WORKTREE" "$@"
}

# Abort with a helpful message if the repo hasn't been initialized yet
assert_initialized() {
    if [[ ! -d "$SNAP_REPO" ]]; then
        echo "Error: Snapshot repository has not been initialized." >&2
        echo "Run '$0 init' or 'make snapshot-init' first." >&2
        exit 1
    fi
}

# ---- Command implementations ----

do_init() {
    if [[ -d "$SNAP_REPO" ]]; then
        echo "Snapshot repository already exists at $SNAP_REPO"
        return 0
    fi

    git init --bare "$SNAP_REPO"

    # Restrict tracking to the container mount points only; source files
    # belong to the main project repo and should not appear in snapshots.
    cat > "$SNAP_REPO/info/exclude" <<'EOF'
# Snapshot repo: only track agent runtime directories (home/, log/).
# Everything else is managed by the main source repo.
# Note: mail is stored in ~/Maildir/ (inside home/) since the switch to Maildir format.

# Ignore everything by default
/*

# Track the container mount points
!/home
!/log

# Skip .gitkeep files (those belong to the main repo)
.gitkeep

# Skip binary journal files (large, not useful in git)
log/journal/
EOF

    echo "Snapshot repository initialized at $SNAP_REPO"
    echo "Run 'make snapshot' or '$0 create' to take a snapshot."
}

do_create() {
    assert_initialized

    local msg="${1:-snapshot $(date -Is)}"

    snap_git add -A

    if snap_git diff --cached --quiet 2>/dev/null; then
        if snap_git rev-parse HEAD &>/dev/null; then
            echo "No changes to snapshot."
            return 0
        fi
        if [[ -z "$(snap_git diff --cached --name-only 2>/dev/null)" ]]; then
            echo "No files to snapshot. Are the mount directories (home/, log/) empty?"
            return 0
        fi
    fi

    snap_git commit -m "$msg"
    echo "Snapshot created."
}

do_log() {
    assert_initialized
    snap_git log --oneline --decorate "$@"
}

do_diff() {
    assert_initialized
    snap_git diff "$@"
}

do_show() {
    assert_initialized
    snap_git show "$@"
}

do_status() {
    assert_initialized

    # Stage everything so the summary reflects the full picture
    snap_git add -A

    echo "Changes since last snapshot:"
    echo ""
    if snap_git diff --cached --quiet 2>/dev/null && snap_git rev-parse HEAD &>/dev/null; then
        echo "  (no changes)"
    else
        snap_git diff --cached --stat 2>/dev/null || echo "  (first snapshot pending — run 'create' to commit)"
    fi
}

do_help() {
    cat <<'EOF'
Usage: snapshot-agents.sh <command> [args]

Snapshot agent runtime state (home directories including Maildir, logs)
using a separate git repository that doesn't interfere with the main source repo.

Commands:
  init              Initialize the snapshot repository
  create [message]  Take a snapshot (default message: current timestamp)
  log [git-args]    Show snapshot history (pass extra args to git log)
  diff [git-args]   Show changes since last snapshot
  show [git-args]   Show a specific snapshot
  status            Summarize what changed since last snapshot
  help              Show this help

Examples:
  snapshot-agents.sh init
  snapshot-agents.sh create "after alice finished task 3"
  snapshot-agents.sh log -5
  snapshot-agents.sh diff HEAD~1
  snapshot-agents.sh status

Makefile targets:
  make snapshot-init             Initialize the snapshot repo
  make snapshot                  Take a snapshot
  make snapshot MSG="my note"    Take a snapshot with a custom message
  make snapshot-log              Show snapshot history
  make snapshot-diff             Show changes since last snapshot
  make snapshot-status           Summarize changes since last snapshot
EOF
}

# ---- Dispatch ----
case "${1:-help}" in
    init)
        do_init
        ;;
    create)
        shift
        do_create "${1:-}"
        ;;
    log)
        shift
        do_log "$@"
        ;;
    diff)
        shift
        do_diff "$@"
        ;;
    show)
        shift
        do_show "$@"
        ;;
    status)
        do_status
        ;;
    help|--help|-h)
        do_help
        ;;
    *)
        echo "Error: Unknown command '$1'" >&2
        echo "Run '$0 help' for usage." >&2
        exit 1
        ;;
esac
