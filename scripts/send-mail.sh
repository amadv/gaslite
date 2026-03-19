#!/bin/bash
# send-mail.sh — Deliver a mail message to a local agent user
#
# Usage: send-mail.sh <recipient> [--from <user>] [--subject <text>] -- <message>
#
# Sends a local message to the specified agent. Without --from, mail
# originates from root. With --from, the command runs as that user.
#
# Options:
#   --from <user>       Send as this user (executes mail as that user)
#   --subject <text>    Mail subject line (default: "Message")
#
# Examples:
#   send-mail.sh alice -- "Hello from root"
#   send-mail.sh alice --from bob -- "Hello from bob"
#   send-mail.sh alice --from bob --subject "Meeting" -- "Let's sync up"

set -euo pipefail

readonly HELP_TEXT="Usage: send-mail.sh <recipient> [--from <user>] [--subject <text>] -- <message>"

# --- Container check ---
# When invoked from the host, forward the call into the running container.
# Set AGENT_HOST_CONTAINER to override the default container name.
if [[ ! -f /.dockerenv ]]; then
    CONTAINER="${AGENT_HOST_CONTAINER:-gaslite}"
    exec docker exec "$CONTAINER" /usr/local/bin/"$(basename "$0")" "$@"
fi

# --- Argument parsing ---
TARGET=""
SENDER=""
MAIL_SUBJECT="Message"
BODY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --from requires a value." >&2
                echo "$HELP_TEXT" >&2
                exit 1
            fi
            SENDER="$2"
            shift 2
            ;;
        --subject)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --subject requires a value." >&2
                echo "$HELP_TEXT" >&2
                exit 1
            fi
            MAIL_SUBJECT="$2"
            shift 2
            ;;
        --)
            shift
            BODY="$*"
            break
            ;;
        -*)
            echo "Error: Unknown option '$1'." >&2
            echo "$HELP_TEXT" >&2
            exit 1
            ;;
        *)
            if [[ -z "$TARGET" ]]; then
                TARGET="$1"
            else
                # Accept remaining args as body when no -- separator given
                BODY="$*"
                break
            fi
            shift
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "Error: Recipient is required." >&2
    echo "$HELP_TEXT" >&2
    exit 1
fi

if [[ -z "$BODY" ]]; then
    echo "Error: Message body is required." >&2
    echo "$HELP_TEXT" >&2
    exit 1
fi

# Confirm recipient is a known user or a defined mail alias
if ! id "$TARGET" &>/dev/null; then
    if ! grep -q "^${TARGET}:" /etc/smtpd/aliases 2>/dev/null; then
        echo "Error: Recipient '$TARGET' is not a user or a known mail alias." >&2
        exit 1
    fi
fi

# Confirm sender account exists when one was specified
if [[ -n "$SENDER" ]]; then
    if ! id "$SENDER" &>/dev/null; then
        echo "Error: Sender '$SENDER' does not exist." >&2
        exit 1
    fi
fi

# Deliver the message
if [[ -n "$SENDER" ]]; then
    printf '%s\n' "$BODY" | runuser -u "$SENDER" -- mail -s "$MAIL_SUBJECT" "$TARGET"
    echo "Mail sent to $TARGET from $SENDER."
else
    printf '%s\n' "$BODY" | mail -s "$MAIL_SUBJECT" "$TARGET"
    echo "Mail sent to $TARGET from root."
fi
