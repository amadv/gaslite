#!/bin/bash
# agent-env.sh — Common environment settings for all agent login shells

# Mark this shell as running inside the agent hosting container
export AGENT_PLATFORM="docker"
export AGENT_HOST=1

# Mail location — OpenSMTPD delivers to ~/Maildir/ in Maildir format
export MAIL="$HOME/Maildir"

# Ensure management scripts are on PATH
if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
    export PATH="/usr/local/bin:$PATH"
fi

# Agent home directories are private by default; new files are not group/world readable
umask 077
