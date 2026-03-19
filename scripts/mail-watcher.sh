#!/bin/bash
# mail-watcher.sh — inotify-driven monitor for Maildir message delivery
#
# Usage: mail-watcher.sh (launched by create-agent.sh / agent-manager.sh)
#
# Monitors ~/Maildir/new/ via inotifywait and emits a log line for each
# incoming message. Delivered messages stay in new/ — s-nail moves them
# to cur/ when read, preserving standard Maildir conventions
# (new/ = unread, cur/ = already seen).
#
# Provides the base infrastructure for Phase 2 work-queue integration,
# where incoming mail will be parsed and turned into work items.
#
# The Delivered-To header (injected by OpenSMTPD as the first line of
# each message) holds the original envelope recipient address.

set -euo pipefail

readonly CURRENT_USER="$(whoami)"
readonly MAIL_ROOT="$HOME/Maildir"
readonly INBOX_DIR="$MAIL_ROOT/new"
readonly PID_RECORD="$HOME/.mail-watcher.pid"

# Store our real PID — the launcher holds the su wrapper's PID, not ours
echo $$ > "$PID_RECORD"
trap 'rm -f "$PID_RECORD"' EXIT

stamp() {
    echo "[$(date -Iseconds)] mail-watcher(${CURRENT_USER}): $*"
}

# Build the Maildir folder hierarchy if anything is absent
for folder in "$MAIL_ROOT" "$INBOX_DIR" "$MAIL_ROOT/cur" "$MAIL_ROOT/tmp"; do
    if [[ ! -d "$folder" ]]; then
        mkdir -p "$folder"
        stamp "Created $folder"
    fi
done

stamp "Watching $INBOX_DIR for incoming mail (PID $$)"

# Begin monitoring; handle both direct writes and atomic renames from tmp/
# CREATE covers OpenSMTPD writing directly into new/
# MOVED_TO covers the standard tmp/ -> new/ rename sequence
inotifywait -m -e create -e moved_to --format '%f' "$INBOX_DIR" 2>/dev/null |
while IFS= read -r filename; do
    stamp "New mail: $filename"
done
