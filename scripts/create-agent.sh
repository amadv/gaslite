#!/bin/bash
# create-agent.sh — Provision a new agent account with persona and API credentials
#
# Usage: create-agent.sh <username> [--persona <name>] [--instructions <text>] [--api-key <PROVIDER>=<key>]...
#
# Steps performed:
#   1. Adds a Linux user (home populated from /etc/skel)
#   2. Assigns user to the 'agents' group
#   3. Assembles agents.md from base persona + optional specialist role + custom instructions
#   4. Sets up an agent-writable .claude/ directory (with skills/ subdirectory)
#      containing a root-owned read-only config.json
#   5. Writes git identity (user.name, user.email)
#   6. Populates SSH known_hosts for common git forges (github.com, gitlab.com)
#   7. Stores per-worker API credentials if supplied
#   8. Enables and starts the agent@<username> systemd service
#
# Options:
#   --persona <name>            Attach a specialist role profile (e.g., coder, researcher)
#   --instructions <text>       Extra instructions appended to agents.md
#   --api-key <PROVIDER>=<key>  Assign an API credential to this agent (repeatable)
#
# Role resolution:
#   - The base profile (/etc/agent-personas/base.md) is always included
#   - With --persona <name>, the matching /etc/agent-personas/<name>.md is appended
#   - Without --persona, only the base profile is used
#
# Examples:
#   create-agent.sh alice --api-key ANTHROPIC_API_KEY=sk-ant-xxx
#   create-agent.sh bob --persona coder --api-key OPENAI_API_KEY=sk-xxx
#   create-agent.sh carol --persona coder --instructions "Focus on Python backend code"

set -euo pipefail

# --- Environment check ---
# When invoked outside the container, forward the call through docker exec.
# Override the target container name via AGENT_HOST_CONTAINER.
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec ${CONTAINER_RUNTIME:-docker} exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

readonly ROLE_DIR="/etc/agent-personas"

# --- Argument parsing ---
TARGET=""
ROLE=""
EXTRA_INSTRUCTIONS=""
CREDENTIALS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --persona)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --persona needs a value." >&2
                echo "Usage: create-agent.sh <username> [--persona <name>] [--instructions <text>] [--api-key <PROVIDER>=<key>]..." >&2
                exit 1
            fi
            ROLE="$2"
            shift 2
            ;;
        --instructions)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --instructions needs a value." >&2
                echo "Usage: create-agent.sh <username> [--persona <name>] [--instructions <text>] [--api-key <PROVIDER>=<key>]..." >&2
                exit 1
            fi
            EXTRA_INSTRUCTIONS="$2"
            shift 2
            ;;
        --api-key)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --api-key needs a value in PROVIDER=key format." >&2
                echo "Usage: create-agent.sh <username> [--persona <name>] [--instructions <text>] [--api-key <PROVIDER>=<key>]..." >&2
                exit 1
            fi
            if [[ ! "$2" =~ ^[A-Z_][A-Z0-9_]*=.+$ ]]; then
                echo "Error: Malformed API key '$2'. Expected PROVIDER=key (e.g., ANTHROPIC_API_KEY=sk-xxx)." >&2
                exit 1
            fi
            CREDENTIALS+=("$2")
            shift 2
            ;;
        -*)
            echo "Error: Unrecognised option '$1'." >&2
            echo "Usage: create-agent.sh <username> [--persona <name>] [--instructions <text>] [--api-key <PROVIDER>=<key>]..." >&2
            exit 1
            ;;
        *)
            if [[ -z "$TARGET" ]]; then
                TARGET="$1"
            else
                echo "Error: Surplus argument '$1'." >&2
                echo "Usage: create-agent.sh <username> [--persona <name>] [--instructions <text>] [--api-key <PROVIDER>=<key>]..." >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "Usage: create-agent.sh <username> [--persona <name>] [--instructions <text>] [--api-key <PROVIDER>=<key>]..." >&2
    exit 1
fi

# Validate account name: lowercase letter or underscore first, then [a-z0-9_-], max 32 chars
if ! [[ "$TARGET" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Error: Invalid account name '$TARGET'." >&2
    echo "Must begin with a lowercase letter or underscore, only [a-z0-9_-] allowed, max 32 chars." >&2
    exit 1
fi

# Refuse to proceed if account already exists
if id "$TARGET" &>/dev/null; then
    echo "Error: Account '$TARGET' already exists." >&2
    exit 1
fi

# Validate the requested role profile
if [[ -n "$ROLE" ]]; then
    ROLE_FILE="${ROLE_DIR}/${ROLE%.md}.md"
    if [[ ! -f "$ROLE_FILE" ]]; then
        echo "Error: Role profile '${ROLE}' not found at ${ROLE_FILE}" >&2
        echo "Available profiles:" >&2
        for f in "${ROLE_DIR}"/*.md; do
            pname="$(basename "$f" .md)"
            [[ "$pname" == "base" ]] && continue
            echo "  - $pname" >&2
        done
        exit 1
    fi
fi

echo "Provisioning agent account: $TARGET"

# 1. Create the Linux account
# Extract Role and Purpose from the persona file to populate the GECOS field,
# allowing peer agents to discover this agent's function via getent passwd.
GECOS_FIELD="Agent"
if [[ -n "$ROLE" ]]; then
    ROLE_FILE="${ROLE_DIR}/${ROLE%.md}.md"
    ROLE_LINE=$(grep -m1 '^\- \*\*Role\*\*:' "$ROLE_FILE" 2>/dev/null || true)
    if [[ -n "$ROLE_LINE" ]]; then
        GECOS_FIELD=$(echo "$ROLE_LINE" | sed 's/^- \*\*Role\*\*: *//')
    fi
    PURPOSE_LINE=$(grep -m1 '^\- \*\*Purpose\*\*:' "$ROLE_FILE" 2>/dev/null || true)
    if [[ -n "$PURPOSE_LINE" ]]; then
        PURPOSE_TEXT=$(echo "$PURPOSE_LINE" | sed 's/^- \*\*Purpose\*\*: *//')
        GECOS_FIELD="$GECOS_FIELD (${ROLE%.md}) - $PURPOSE_TEXT"
    else
        GECOS_FIELD="$GECOS_FIELD (${ROLE%.md})"
    fi
fi

# Create a persona-named group so agents sharing a role can be reached collectively
SUPPLEMENTAL_GROUPS="agents"
if [[ -n "$ROLE" ]]; then
    ROLE_GROUP="${ROLE%.md}"
    if ! getent group "$ROLE_GROUP" &>/dev/null; then
        groupadd "$ROLE_GROUP"
        echo "  -> Created role group: $ROLE_GROUP"
    fi
    SUPPLEMENTAL_GROUPS="agents,$ROLE_GROUP"
fi

# useradd -M avoids the home dir creation issue on Docker bind mounts (VirtioFS on macOS)
useradd -M -s /bin/bash -G "$SUPPLEMENTAL_GROUPS" -c "$GECOS_FIELD" -d "/home/$TARGET" "$TARGET"

# Manually populate home directory from skeleton
mkdir -p "/home/$TARGET"
cp -a /etc/skel/. "/home/$TARGET/"
chown -R "$TARGET:$TARGET" "/home/$TARGET"
chmod 700 "/home/$TARGET"
echo "  -> Account provisioned with home at /home/$TARGET (mode 700)"

# Maildir structure for local delivery via OpenSMTPD (~/Maildir/new/)
MAIL_HOME="/home/$TARGET/Maildir"
mkdir -p "$MAIL_HOME/new" "$MAIL_HOME/cur" "$MAIL_HOME/tmp"
chown -R "$TARGET:$TARGET" "$MAIL_HOME"
chmod 700 "$MAIL_HOME"
echo "  -> Maildir provisioned at $MAIL_HOME"

# Rebuild mail alias table so the new account joins the 'all' alias
/usr/local/bin/sync-aliases.sh

# 2. Assemble agents.md from base + optional specialist role profile
PERSONA_DOC="/home/$TARGET/agents.md"
{
    if [[ -f "${ROLE_DIR}/base.md" ]]; then
        cat "${ROLE_DIR}/base.md"
    else
        echo "# Agent Configuration"
        echo ""
        echo "No base persona found. Configure this agent by editing this file."
    fi

    if [[ -n "$ROLE" ]]; then
        ROLE_FILE="${ROLE_DIR}/${ROLE%.md}.md"
        echo ""
        echo "---"
        echo ""
        cat "$ROLE_FILE"
    fi

    if [[ -n "$EXTRA_INSTRUCTIONS" ]]; then
        echo ""
        echo "---"
        echo ""
        echo "## Custom Instructions"
        echo ""
        echo "$EXTRA_INSTRUCTIONS"
    fi
} > "$PERSONA_DOC"

chown "$TARGET:$TARGET" "$PERSONA_DOC"
chmod 644 "$PERSONA_DOC"

if [[ -n "$ROLE" ]]; then
    echo "  -> Persona: base + ${ROLE%.md}"
else
    echo "  -> Persona: base (default)"
fi

if [[ -n "$EXTRA_INSTRUCTIONS" ]]; then
    echo "  -> Additional instructions appended to agents.md"
fi

# 3. Prepare .claude/ directory
# The SDK requires write access at runtime for sessions, projects, todos, etc.
# config.json is root-owned so agents cannot alter their own metadata.
SDK_DIR="/home/$TARGET/.claude"
mkdir -p "$SDK_DIR"
chown "$TARGET:$TARGET" "$SDK_DIR"
chmod 755 "$SDK_DIR"

cat > "$SDK_DIR/config.json" <<CONF
{
  "agent": {
    "enabled": true,
    "persona": "${ROLE:-base}"
  }
}
CONF
chown root:root "$SDK_DIR/config.json"
chmod 644 "$SDK_DIR/config.json"

# Skills subdirectory for Claude Code skill packs
mkdir -p "$SDK_DIR/skills"
chown "$TARGET:$TARGET" "$SDK_DIR/skills"

# Distribute skills from the system skill store
SKILLS_STORE="/etc/agent-skills"
SKILLS_DEST="$SDK_DIR/skills"

deploy_skills() {
    local src="$1"
    [[ -d "$src" ]] || return 0
    for pack in "$src"/*/; do
        [[ -d "$pack" ]] || continue
        local pack_name
        pack_name="$(basename "$pack")"
        # Preserve any existing agent customisations
        if [[ ! -d "$SKILLS_DEST/$pack_name" ]]; then
            cp -r "$pack" "$SKILLS_DEST/$pack_name"
            chown -R "$TARGET:$TARGET" "$SKILLS_DEST/$pack_name"
        fi
    done
}

# All-agent skills first, then role-specific packs
deploy_skills "$SKILLS_STORE/_universal"
if [[ -n "$ROLE" ]]; then
    deploy_skills "$SKILLS_STORE/${ROLE%.md}"
fi

INSTALLED_SKILLS=$(find "$SKILLS_DEST" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
echo "  -> Skills deployed: $INSTALLED_SKILLS"

echo "  -> .claude/ directory ready (agent-writable, config.json root-owned)"

# 4. Write git identity
# Derive display name from account + role; write via git config to avoid injection risks.
GIT_DISPLAY="$TARGET"
if [[ -n "$ROLE" ]]; then
    GIT_DISPLAY="$TARGET (${ROLE%.md})"
fi
GIT_ADDR="${TARGET}@gaslite"
git config --file "/home/$TARGET/.gitconfig" user.name "$GIT_DISPLAY"
git config --file "/home/$TARGET/.gitconfig" user.email "$GIT_ADDR"
chown "$TARGET:$TARGET" "/home/$TARGET/.gitconfig"
echo "  -> Git identity: $GIT_DISPLAY <$GIT_ADDR>"

# 5. Populate SSH known_hosts for non-interactive forge access
# Best-effort only — agent provisioning must not fail in restricted network environments.
KEYS_DIR="/home/$TARGET/.ssh"
mkdir -p "$KEYS_DIR"
chmod 700 "$KEYS_DIR"
ssh-keyscan -t ed25519,rsa github.com gitlab.com 2>/dev/null > "$KEYS_DIR/known_hosts" || true
if [[ -s "$KEYS_DIR/known_hosts" ]]; then
    echo "  -> SSH known_hosts written (github.com, gitlab.com)"
else
    echo "  Warning: ssh-keyscan returned nothing (network unreachable?); SSH host verification may prompt." >&2
fi
chmod 644 "$KEYS_DIR/known_hosts"
chown -R "$TARGET:$TARGET" "$KEYS_DIR"

# 6. Store per-agent API credentials when supplied
if [[ ${#CREDENTIALS[@]} -gt 0 ]]; then
    CREDS_FILE="$SDK_DIR/api-keys.env"
    {
        echo "# API credentials for agent: $TARGET"
        echo "# Written by create-agent.sh — use manage-api-keys.sh to update"
        echo "# Created: $(date -Iseconds)"
        echo ""
        for pair in "${CREDENTIALS[@]}"; do
            echo "$pair"
        done
    } > "$CREDS_FILE"
    chown root:root "$CREDS_FILE"
    chmod 640 "$CREDS_FILE"
    chgrp "$(id -gn "$TARGET")" "$CREDS_FILE"
    echo "  -> API credentials stored (${#CREDENTIALS[@]} key(s))"
fi

# 7. Activate the agent service via systemd
# Wait for systemd to finish initialising before enabling services.
if ! timeout --kill-after=5 30 systemctl is-active basic.target &>/dev/null; then
    echo "  Waiting for systemd to finish booting..."
    timeout --kill-after=5 60 systemctl is-system-running --wait 2>/dev/null || true
fi

# Launch the mail watcher (event-driven processing of inbound mail)
WATCH_LOG="/var/log/mail-watcher-${TARGET}.log"
WATCH_PID_FILE="/run/mail-watcher-${TARGET}.pid"

echo "  Starting mail watcher..."
nohup su - "$TARGET" -c "MAIL=/home/$TARGET/Maildir /usr/local/bin/mail-watcher.sh" \
    > "$WATCH_LOG" 2>&1 &
WATCH_PID=$!
echo "$WATCH_PID" > "$WATCH_PID_FILE"
echo "  -> Mail watcher running (PID $WATCH_PID, log: $WATCH_LOG)"

# Pick up the new service instance
systemctl daemon-reload

echo "  Enabling agent@${TARGET}.service..."
timeout --kill-after=5 10 systemctl enable "agent@${TARGET}.service"

echo "  Starting agent@${TARGET}.service..."
if timeout --kill-after=5 15 systemctl start "agent@${TARGET}.service"; then
    echo "  -> agent@${TARGET}.service is active"
else
    echo "  Error: agent@${TARGET}.service did not start." >&2
    echo "  Recent journal output:" >&2
    journalctl -u "agent@${TARGET}.service" --no-pager -n 20 2>/dev/null \
        | sed 's/^/    /' >&2
    echo "  Service status:" >&2
    systemctl status "agent@${TARGET}.service" --no-pager 2>/dev/null \
        | sed 's/^/    /' >&2
    exit 1
fi

echo "Agent '$TARGET' is ready."
