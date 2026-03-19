#!/bin/bash
# agent-manager.sh — Boot-time service reconciliation for all agent accounts
#
# Walks every member of the 'agents' group and ensures their
# agent@<username>.service is enabled and queued to start.
# Invoked once at boot by agent-manager.service (Type=oneshot).

set -euo pipefail

echo "agent-manager: Starting at $(date -Iseconds)"

# The Docker bind mount (./home:/home) replaces whatever the image built into /home,
# so /home/shared must be recreated on every boot if it got wiped.
if [[ ! -d /home/shared ]]; then
    mkdir -p /home/shared
    chgrp agents /home/shared
    chmod 2775 /home/shared
    echo "agent-manager: Created /home/shared (mode 2775, group=agents)"
fi

echo "agent-manager: Reconciling agent services..."

echo "agent-manager: Querying 'agents' group membership..."
MEMBER_LIST=$(getent group agents | cut -d: -f4 | tr ',' ' ')

if [[ -z "$MEMBER_LIST" ]]; then
    echo "agent-manager: No accounts found in 'agents' group."
    echo "agent-manager: Finished at $(date -Iseconds)"
    exit 0
fi

echo "agent-manager: Found agents: ${MEMBER_LIST}"

LAUNCH_COUNT=0
FAIL_COUNT=0

for ACCT in $MEMBER_LIST; do
    # Skip ghost entries — account must exist and have a home directory
    if ! id "$ACCT" &>/dev/null; then
        echo "  [SKIP] $ACCT — account does not exist"
        continue
    fi

    if [[ ! -d "/home/$ACCT" ]]; then
        echo "  [SKIP] $ACCT — home directory absent"
        continue
    fi

    # Ensure the Maildir hierarchy is present (may be absent on pre-Maildir installs)
    MDIR="/home/$ACCT/Maildir"
    if [[ ! -d "$MDIR/new" ]]; then
        mkdir -p "$MDIR/new" "$MDIR/cur" "$MDIR/tmp"
        chown -R "$ACCT:$ACCT" "$MDIR"
        chmod 700 "$MDIR"
        echo "  [INIT] $ACCT — created Maildir"

        # One-time migration: import legacy mbox messages into Maildir/cur/
        LEGACY_MBOX="/var/spool/mail/$ACCT"
        if [[ -f "$LEGACY_MBOX" ]] && [[ -s "$LEGACY_MBOX" ]]; then
            # mbox messages begin with "From " at column 0; split them with awk
            awk -v cur="$MDIR/cur" '
                /^From / {
                    if (out) close(out)
                    msgnum++
                    out = cur "/" systime() "." msgnum ".migrated:2,"
                    next
                }
                out { print > out }
            ' "$LEGACY_MBOX"
            chown -R "$ACCT:$ACCT" "$MDIR/cur"
            echo "  [MIGR] $ACCT — imported legacy mbox mail"
        fi
    fi

    # Enable and start the agent service; timeouts guard against D-Bus hangs
    echo "  Enabling agent@${ACCT}.service..."
    timeout --kill-after=5 10 systemctl enable "agent@${ACCT}.service" 2>/dev/null || true

    echo "  Starting agent@${ACCT}.service..."
    if timeout --kill-after=5 10 systemctl start --no-block "agent@${ACCT}.service" 2>/dev/null; then
        echo "  [OK]   $ACCT — agent starting"
        ((LAUNCH_COUNT++))
    else
        echo "  [FAIL] $ACCT — agent failed to queue start"
        ((FAIL_COUNT++))
    fi

    # Launch the mail watcher as the agent user (not systemd-managed)
    WATCHER_LOGFILE="/var/log/mail-watcher-${ACCT}.log"
    WRAPPER_PIDFILE="/run/mail-watcher-${ACCT}.pid"
    SELF_PIDFILE="/home/${ACCT}/.mail-watcher.pid"

    # Clear out any stale PID files from the previous boot
    if [[ -f "$SELF_PIDFILE" ]]; then
        kill "$(cat "$SELF_PIDFILE")" 2>/dev/null || true
        rm -f "$SELF_PIDFILE"
    fi
    if [[ -f "$WRAPPER_PIDFILE" ]]; then
        kill "$(cat "$WRAPPER_PIDFILE")" 2>/dev/null || true
        rm -f "$WRAPPER_PIDFILE"
    fi

    nohup su - "$ACCT" -c "MAIL=/home/$ACCT/Maildir /usr/local/bin/mail-watcher.sh" \
        > "$WATCHER_LOGFILE" 2>&1 &
    echo "$!" > "$WRAPPER_PIDFILE"
    echo "  [OK]   $ACCT — mail watcher started"
done

# Rebuild aliases so they reflect the current set of active agents
/usr/local/bin/sync-aliases.sh

echo "agent-manager: Done. Started=$LAUNCH_COUNT Failed=$FAIL_COUNT"
echo "agent-manager: Finished at $(date -Iseconds)"
