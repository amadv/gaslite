#!/bin/bash
# manage-api-keys.sh — Manage API keys for agents
#
# Usage:
#   manage-api-keys.sh set <username> <PROVIDER>=<key> [<PROVIDER>=<key> ...]
#   manage-api-keys.sh get <username> [PROVIDER]
#   manage-api-keys.sh remove <username> <PROVIDER> [<PROVIDER> ...]
#   manage-api-keys.sh clear <username>
#   manage-api-keys.sh list-providers
#
# Per-agent API keys live in ~/.claude/api-keys.env and are root-owned
# but agent-readable.
#
# Examples:
#   manage-api-keys.sh set alice ANTHROPIC_API_KEY=sk-ant-xxx
#   manage-api-keys.sh set bob OPENAI_API_KEY=sk-xxx MISTRAL_API_KEY=xxx
#   manage-api-keys.sh get alice
#   manage-api-keys.sh get alice ANTHROPIC_API_KEY
#   manage-api-keys.sh remove alice OPENAI_API_KEY
#   manage-api-keys.sh clear alice
#   manage-api-keys.sh list-providers

set -euo pipefail

# --- Container check ---
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec docker exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

# Recognised API credential variables (for display and documentation purposes)
readonly SUPPORTED_PROVIDERS=(
    "ANTHROPIC_API_KEY"
    "OPENAI_API_KEY"
    "GOOGLE_API_KEY"
    "GEMINI_API_KEY"
    "MISTRAL_API_KEY"
    "COHERE_API_KEY"
    "GROQ_API_KEY"
    "TOGETHER_API_KEY"
    "FIREWORKS_API_KEY"
    "PERPLEXITY_API_KEY"
    "REPLICATE_API_TOKEN"
    "HUGGINGFACE_API_KEY"
    "HF_TOKEN"
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
    "AWS_DEFAULT_REGION"
    "AZURE_OPENAI_API_KEY"
    "AZURE_OPENAI_ENDPOINT"
    "GITHUB_TOKEN"
    "GH_TOKEN"
)

print_usage() {
    cat <<'EOF'
Usage:
  manage-api-keys.sh set <username> <PROVIDER>=<key> [<PROVIDER>=<key> ...]
  manage-api-keys.sh get <username> [PROVIDER]
  manage-api-keys.sh remove <username> <PROVIDER> [<PROVIDER> ...]
  manage-api-keys.sh clear <username>
  manage-api-keys.sh list-providers

Commands:
  set            Set one or more API keys for an agent
  get            Show API keys for an agent (values masked by default)
  remove         Remove specific API keys from an agent
  clear          Remove all API keys from an agent
  list-providers List known API key provider names

Examples:
  manage-api-keys.sh set alice ANTHROPIC_API_KEY=sk-ant-xxx
  manage-api-keys.sh set bob OPENAI_API_KEY=sk-xxx MISTRAL_API_KEY=xxx
  manage-api-keys.sh get alice
  manage-api-keys.sh remove alice OPENAI_API_KEY
  manage-api-keys.sh clear alice
EOF
    exit 1
}

check_agent() {
    local acct="$1"
    if ! [[ "$acct" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo "Error: Invalid username '$acct'." >&2
        exit 1
    fi
    if ! id "$acct" &>/dev/null; then
        echo "Error: User '$acct' does not exist." >&2
        exit 1
    fi
    if ! id -nG "$acct" | grep -qw agents; then
        echo "Error: User '$acct' is not in the 'agents' group." >&2
        exit 1
    fi
}

keyfile_path() {
    local acct="$1"
    echo "/home/${acct}/.claude/api-keys.env"
}

init_claude_dir() {
    local acct="$1"
    local dot_claude="/home/${acct}/.claude"
    if [[ ! -d "$dot_claude" ]]; then
        mkdir -p "$dot_claude"
        chown root:root "$dot_claude"
        chmod 755 "$dot_claude"
    fi
}

# Redact key value for safe display (keep first and last 4 chars)
redact() {
    local raw="$1"
    local chars=${#raw}
    if [[ $chars -le 8 ]]; then
        echo "********"
    else
        echo "${raw:0:4}...${raw: -4}"
    fi
}

do_set() {
    if [[ $# -lt 2 ]]; then
        echo "Error: 'set' requires a username and at least one KEY=value pair." >&2
        print_usage
    fi

    local acct="$1"
    shift
    check_agent "$acct"
    init_claude_dir "$acct"

    local kfile
    kfile="$(keyfile_path "$acct")"

    # Validate and collect incoming key=value pairs
    declare -A incoming
    for entry in "$@"; do
        if [[ ! "$entry" =~ ^[A-Z_][A-Z0-9_]*=.+$ ]]; then
            echo "Error: Invalid format '$entry'. Use PROVIDER=key format." >&2
            exit 1
        fi
        local prov="${entry%%=*}"
        local val="${entry#*=}"
        incoming["$prov"]="$val"
    done

    # Load whatever keys already exist
    declare -A stored
    if [[ -f "$kfile" ]]; then
        while IFS='=' read -r k v; do
            [[ "$k" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$k" ]] && continue
            k="$(echo "$k" | xargs)"
            stored["$k"]="$v"
        done < "$kfile"
    fi

    # Overlay incoming onto stored
    for prov in "${!incoming[@]}"; do
        stored["$prov"]="${incoming[$prov]}"
    done

    # Persist the merged set
    {
        echo "# API keys for agent: $acct"
        echo "# Managed by manage-api-keys.sh - do not edit directly"
        echo "# Generated: $(date -Iseconds)"
        echo ""
        for prov in "${!stored[@]}"; do
            echo "${prov}=${stored[$prov]}"
        done
    } > "$kfile"

    chown root:root "$kfile"
    chmod 640 "$kfile"
    # Give the agent read access via its primary group
    chgrp "$(id -gn "$acct")" "$kfile"

    echo "API keys updated for agent '$acct':"
    for prov in "${!incoming[@]}"; do
        echo "  $prov = $(redact "${incoming[$prov]}")"
    done
}

do_get() {
    if [[ $# -lt 1 ]]; then
        echo "Error: 'get' requires a username." >&2
        print_usage
    fi

    local acct="$1"
    local wanted="${2:-}"
    check_agent "$acct"

    local kfile
    kfile="$(keyfile_path "$acct")"

    if [[ ! -f "$kfile" ]]; then
        echo "No API keys configured for agent '$acct'."
        return 0
    fi

    echo "API keys for agent '$acct':"
    local hit=false
    while IFS='=' read -r k v; do
        [[ "$k" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$k" ]] && continue
        k="$(echo "$k" | xargs)"

        if [[ -n "$wanted" ]]; then
            if [[ "$k" == "$wanted" ]]; then
                echo "  $k = $(redact "$v")"
                hit=true
            fi
        else
            echo "  $k = $(redact "$v")"
            hit=true
        fi
    done < "$kfile"

    if [[ "$hit" == "false" ]]; then
        if [[ -n "$wanted" ]]; then
            echo "  (no key found for $wanted)"
        else
            echo "  (no keys configured)"
        fi
    fi
}

do_remove() {
    if [[ $# -lt 2 ]]; then
        echo "Error: 'remove' requires a username and at least one provider name." >&2
        print_usage
    fi

    local acct="$1"
    shift
    check_agent "$acct"

    local kfile
    kfile="$(keyfile_path "$acct")"

    if [[ ! -f "$kfile" ]]; then
        echo "No API keys configured for agent '$acct'."
        return 0
    fi

    # Read current contents
    declare -A stored
    while IFS='=' read -r k v; do
        [[ "$k" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$k" ]] && continue
        k="$(echo "$k" | xargs)"
        stored["$k"]="$v"
    done < "$kfile"

    # Drop the requested keys
    local dropped=()
    for prov in "$@"; do
        if [[ -v stored["$prov"] ]]; then
            unset 'stored[$prov]'
            dropped+=("$prov")
        else
            echo "Warning: '$prov' not found for agent '$acct'." >&2
        fi
    done

    # Persist what remains
    if [[ ${#stored[@]} -eq 0 ]]; then
        rm -f "$kfile"
        echo "All API keys removed for agent '$acct'."
    else
        {
            echo "# API keys for agent: $acct"
            echo "# Managed by manage-api-keys.sh - do not edit directly"
            echo "# Generated: $(date -Iseconds)"
            echo ""
            for prov in "${!stored[@]}"; do
                echo "${prov}=${stored[$prov]}"
            done
        } > "$kfile"
        chown root:root "$kfile"
        chmod 640 "$kfile"
        chgrp "$(id -gn "$acct")" "$kfile"

        if [[ ${#dropped[@]} -gt 0 ]]; then
            echo "Removed API keys for agent '$acct': ${dropped[*]}"
        fi
    fi
}

do_clear() {
    if [[ $# -lt 1 ]]; then
        echo "Error: 'clear' requires a username." >&2
        print_usage
    fi

    local acct="$1"
    check_agent "$acct"

    local kfile
    kfile="$(keyfile_path "$acct")"

    if [[ -f "$kfile" ]]; then
        rm -f "$kfile"
        echo "All API keys cleared for agent '$acct'."
    else
        echo "No API keys configured for agent '$acct'."
    fi
}

do_list_providers() {
    echo "Known API key providers:"
    echo ""
    for prov in "${SUPPORTED_PROVIDERS[@]}"; do
        echo "  $prov"
    done
    echo ""
    echo "Note: You can use any PROVIDER_NAME=value format, not just these."
}

# --- Entry point ---
if [[ $# -lt 1 ]]; then
    print_usage
fi

ACTION="$1"
shift

case "$ACTION" in
    set)
        do_set "$@"
        ;;
    get)
        do_get "$@"
        ;;
    remove)
        do_remove "$@"
        ;;
    clear)
        do_clear "$@"
        ;;
    list-providers)
        do_list_providers
        ;;
    *)
        echo "Error: Unknown command '$ACTION'." >&2
        print_usage
        ;;
esac
