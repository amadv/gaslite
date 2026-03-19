#!/bin/bash
# soft-reset.sh — Wipe all agents and flush logs inside the container
#
# Usage: soft-reset.sh [--yes]
#
# Steps performed:
#   1. Deletes every agent user (stops services, removes accounts and home dirs)
#   2. Rotates and vacuums the systemd journal
#   3. Mail is gone automatically because it lives in Maildir inside home dirs

set -euo pipefail

# Proxy to the container when invoked from the host side.
# Set AGENT_HOST_CONTAINER to override the default container name.
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec docker exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

AUTO_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) AUTO_CONFIRM=true ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# Prompt the operator before doing anything destructive
if [[ "$AUTO_CONFIRM" != true ]]; then
    echo "This will:"
    echo "  - Remove all agent users (services, accounts, and home directories)"
    echo "  - Clear all systemd journal logs"
    echo "  - Clear mail (stored in home directories as Maildir)"
    echo ""
    read -r -p "Continue? [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Tear down every agent account
MEMBER_LIST=$(getent group agents 2>/dev/null | cut -d: -f4 | tr ',' ' ')

if [[ -n "$MEMBER_LIST" ]]; then
    for ACCT in $MEMBER_LIST; do
        echo "Removing agent: $ACCT"
        /usr/local/bin/remove-agent.sh "$ACCT"
    done
else
    echo "No agent users found."
fi

# Rebuild aliases now that all agents are gone (clears the 'all' alias)
/usr/local/bin/sync-aliases.sh

# Flush the journal
echo "Clearing systemd journal..."
journalctl --rotate --vacuum-time=1s 2>/dev/null || true
echo "  -> Journal cleared"

# Mail lived in ~/Maildir/ and was already deleted above with each home directory
echo "  -> Mail cleared (Maildir removed with home directories)"

echo ""
echo "Soft reset complete."
