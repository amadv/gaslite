#!/bin/bash
# nvm.sh — Initialise the system-wide nvm installation for interactive shells
# nvm is installed at /usr/local/share/nvm and is available to all users.
# Agents may run `nvm install <version>` to use a different Node version than
# the system default.

export NVM_DIR="/usr/local/share/nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
fi
if [ -s "$NVM_DIR/bash_completion" ]; then
    . "$NVM_DIR/bash_completion"
fi
