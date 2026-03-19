#!/bin/bash
# list-agents.sh — Display all agent accounts and their current service state
#
# Usage: list-agents.sh

set -euo pipefail

# Proxy to the container when invoked from the host side.
# Set AGENT_HOST_CONTAINER to override the default container name.
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec docker exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

ROSTER=$(getent group agents 2>/dev/null | cut -d: -f4 | tr ',' ' ')

if [[ -z "$ROSTER" ]]; then
    echo "No agent users found."
    exit 0
fi

printf "%-20s %-12s %-10s %s\n" "USER" "SERVICE" "ACTIVE" "HOME"
printf "%-20s %-12s %-10s %s\n" "----" "-------" "------" "----"

for ACCT in $ROSTER; do
    SVC_NAME="agent@${ACCT}.service"
    SVC_STATE=$(timeout --kill-after=5 5 systemctl is-active "$SVC_NAME" 2>/dev/null || echo "inactive")
    ACCT_HOME="/home/$ACCT"
    DIR_STATUS="yes"
    [[ -d "$ACCT_HOME" ]] || DIR_STATUS="missing"

    printf "%-20s %-12s %-10s %s (%s)\n" "$ACCT" "$SVC_NAME" "$SVC_STATE" "$ACCT_HOME" "$DIR_STATUS"
done
