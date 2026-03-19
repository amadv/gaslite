#!/bin/bash
# remove-agent.sh — Tear down an agent user and its associated service
#
# Usage: remove-agent.sh <username> [--keep-home]
#
# Steps performed:
#   1. Kills the mail watcher process (tracked by PID file)
#   2. Stops and disables the agent@<username> systemd service
#   3. Deletes the Linux user account
#   4. Home directory is removed unless --keep-home is passed

set -euo pipefail

# Proxy to the container when invoked from the host side.
# Set AGENT_HOST_CONTAINER to override the default container name.
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec docker exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

PRESERVE_HOME=false

if [[ $# -lt 1 ]]; then
    echo "Usage: remove-agent.sh <username> [--keep-home]" >&2
    exit 1
fi

ACCOUNT="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-home) PRESERVE_HOME=true ;;
        *) echo "Unrecognized option: $1" >&2; exit 1 ;;
    esac
    shift
done

# Verify the user account exists before proceeding
if ! id "$ACCOUNT" &>/dev/null; then
    echo "Error: No such user '$ACCOUNT'." >&2
    exit 1
fi

echo "Removing agent user: $ACCOUNT"

# Stop the mail watcher — not managed by systemd, so we kill by PID
echo "  Stopping mail watcher..."
HOME_PIDFILE="/home/${ACCOUNT}/.mail-watcher.pid"
if [[ -f "$HOME_PIDFILE" ]]; then
    WATCHER_PID="$(cat "$HOME_PIDFILE")"
    if kill -0 "$WATCHER_PID" 2>/dev/null; then
        kill "$WATCHER_PID" 2>/dev/null || true
        echo "  -> Mail watcher stopped (PID $WATCHER_PID)"
    fi
    rm -f "$HOME_PIDFILE"
fi
RUN_PIDFILE="/run/mail-watcher-${ACCOUNT}.pid"
if [[ -f "$RUN_PIDFILE" ]]; then
    kill "$(cat "$RUN_PIDFILE")" 2>/dev/null || true
    rm -f "$RUN_PIDFILE"
fi

# Stop and disable the systemd service
echo "  Checking service status..."
if timeout --kill-after=5 5 systemctl is-enabled "agent@${ACCOUNT}.service" &>/dev/null; then
    echo "  Stopping agent@${ACCOUNT}.service..."
    timeout --kill-after=5 10 systemctl stop "agent@${ACCOUNT}.service" 2>/dev/null || true
    echo "  Disabling agent@${ACCOUNT}.service..."
    timeout --kill-after=5 10 systemctl disable "agent@${ACCOUNT}.service" 2>/dev/null || true
    echo "  -> agent@${ACCOUNT}.service stopped and disabled"
else
    echo "  -> No active service found (skipping)"
fi

# Collect non-standard groups the user belongs to so we can prune empty ones afterward
LEFTOVER_GROUPS=""
ALL_GROUPS=$(id -Gn "$ACCOUNT" 2>/dev/null || true)
PRIMARY_GRP=$(id -gn "$ACCOUNT" 2>/dev/null || true)
for grp in $ALL_GROUPS; do
    [[ "$grp" == "agents" || "$grp" == "$PRIMARY_GRP" ]] && continue
    LEFTOVER_GROUPS="$LEFTOVER_GROUPS $grp"
done

# Delete the user account
if [[ "$PRESERVE_HOME" == true ]]; then
    userdel "$ACCOUNT"
    echo "  -> User removed (home directory kept at /home/$ACCOUNT)"
else
    userdel -r "$ACCOUNT"
    echo "  -> User and home directory removed"
fi

# Remove any persona groups that are now empty
for grp in $LEFTOVER_GROUPS; do
    REMAINING=$(getent group "$grp" 2>/dev/null | cut -d: -f4)
    if [[ -z "$REMAINING" ]]; then
        groupdel "$grp" 2>/dev/null || true
        echo "  -> Removed empty persona group: $grp"
    fi
done

# Rebuild mail aliases so this user is no longer in 'all' or persona aliases
/usr/local/bin/sync-aliases.sh

echo "Agent '$ACCOUNT' has been removed."
