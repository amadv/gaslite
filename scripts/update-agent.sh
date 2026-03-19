#!/bin/bash
# update-agent.sh — Swap out a running agent's persona
#
# Usage: update-agent.sh <username> --persona <name>
#
# Steps performed:
#   1. Confirm the target user account exists
#   2. Confirm the requested persona file is present
#   3. Rebuild agents.md by combining base + specialist persona content
#   4. Write a fresh .claude/config.json reflecting the new persona
#   5. Kick the agent@<username> systemd service to reload the config
#
# Persona notes:
#   - base.md from /etc/agent-personas is always prepended
#   - Pass --persona base to strip specialist content and run base-only

set -euo pipefail

# Proxy to the container when invoked from the host side.
# Set AGENT_HOST_CONTAINER to override the default container name.
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec docker exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

readonly PERSONA_STORE="/etc/agent-personas"

# Argument parsing
TARGET_USER=""
CHOSEN_PERSONA=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --persona)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --persona needs a value." >&2
                echo "Usage: update-agent.sh <username> --persona <name>" >&2
                exit 1
            fi
            CHOSEN_PERSONA="$2"
            shift 2
            ;;
        -*)
            echo "Error: Unrecognized flag '$1'." >&2
            echo "Usage: update-agent.sh <username> --persona <name>" >&2
            exit 1
            ;;
        *)
            if [[ -z "$TARGET_USER" ]]; then
                TARGET_USER="$1"
            else
                echo "Error: Extra argument '$1' not expected." >&2
                echo "Usage: update-agent.sh <username> --persona <name>" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$TARGET_USER" ]]; then
    echo "Usage: update-agent.sh <username> --persona <name>" >&2
    exit 1
fi

if [[ -z "$CHOSEN_PERSONA" ]]; then
    echo "Error: --persona is required." >&2
    echo "Usage: update-agent.sh <username> --persona <name>" >&2
    exit 1
fi

# Confirm the account exists
if ! id "$TARGET_USER" &>/dev/null; then
    echo "Error: No such user '$TARGET_USER'." >&2
    exit 1
fi

# Confirm the account is actually an agent
if ! id -nG "$TARGET_USER" | grep -qw agents; then
    echo "Error: '$TARGET_USER' is not a member of the 'agents' group." >&2
    exit 1
fi

# Confirm the persona file exists (unless reverting to base-only)
if [[ "$CHOSEN_PERSONA" != "base" ]]; then
    SPECIALIST_FILE="${PERSONA_STORE}/${CHOSEN_PERSONA%.md}.md"
    if [[ ! -f "$SPECIALIST_FILE" ]]; then
        echo "Error: Persona '${CHOSEN_PERSONA}' not found at ${SPECIALIST_FILE}" >&2
        echo "Available personas:" >&2
        for f in "${PERSONA_STORE}"/*.md; do
            entry="$(basename "$f" .md)"
            [[ "$entry" == "base" ]] && continue
            echo "  - $entry" >&2
        done
        echo "  - base (revert to base persona only)" >&2
        exit 1
    fi
fi

echo "Updating agent persona: $TARGET_USER"

# Rebuild agents.md — base always first, specialist appended when requested
PERSONA_DOC="/home/$TARGET_USER/agents.md"
{
    if [[ -f "${PERSONA_STORE}/base.md" ]]; then
        cat "${PERSONA_STORE}/base.md"
    else
        echo "# Agent Configuration"
        echo ""
        echo "No base persona found. Edit this file to configure the agent."
    fi

    if [[ "$CHOSEN_PERSONA" != "base" ]]; then
        SPECIALIST_FILE="${PERSONA_STORE}/${CHOSEN_PERSONA%.md}.md"
        echo ""
        echo "---"
        echo ""
        cat "$SPECIALIST_FILE"
    fi
} > "$PERSONA_DOC"

chown "$TARGET_USER:$TARGET_USER" "$PERSONA_DOC"
chmod 644 "$PERSONA_DOC"

if [[ "$CHOSEN_PERSONA" != "base" ]]; then
    echo "  -> Persona: base + ${CHOSEN_PERSONA%.md}"
else
    echo "  -> Persona: base (default)"
fi

# Write updated config.json
CLAUDE_CFG_DIR="/home/$TARGET_USER/.claude"
mkdir -p "$CLAUDE_CFG_DIR"
cat > "$CLAUDE_CFG_DIR/config.json" <<CONF
{
  "agent": {
    "enabled": true,
    "persona": "${CHOSEN_PERSONA}"
  }
}
CONF
chown root:root "$CLAUDE_CFG_DIR/config.json"
chmod 644 "$CLAUDE_CFG_DIR/config.json"
echo "  -> config.json updated"

# Restart the systemd service so the agent picks up the new persona
echo "  Checking service status..."
if timeout --kill-after=5 5 systemctl is-enabled "agent@${TARGET_USER}.service" &>/dev/null; then
    echo "  Restarting agent@${TARGET_USER}.service..."
    if timeout --kill-after=5 10 systemctl restart --no-block "agent@${TARGET_USER}.service" 2>/dev/null; then
        echo "  -> agent@${TARGET_USER}.service restarting"
    else
        echo "  -> agent@${TARGET_USER}.service restart queued (may take a moment)"
    fi
else
    echo "  -> Warning: agent@${TARGET_USER}.service is not enabled (skipped restart)"
fi

echo "Agent '$TARGET_USER' persona updated to '${CHOSEN_PERSONA}'."
