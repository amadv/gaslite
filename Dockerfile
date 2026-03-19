FROM archlinux:latest

# Patch pacman to disable the seccomp sandbox — Docker BuildKit's security
# profile conflicts with it. Then perform a full system upgrade and install
# all required packages in a single layer to minimise image size.
# Note: base-devel pulls in sudo, but agents are explicitly denied access below.
RUN sed -i 's/^#\?DisableSandbox.*/DisableSandbox/' /etc/pacman.conf || true && \
    echo 'DisableSandbox' >> /etc/pacman.conf && \
    pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
    systemd \
    base-devel \
    git \
    github-cli \
    curl \
    wget \
    nodejs \
    npm \
    python \
    python-pip \
    jq \
    ripgrep \
    fd \
    tree \
    vim \
    openssh \
    unzip \
    opensmtpd \
    s-nail \
    inotify-tools && \
    pacman -Scc --noconfirm

# Create the shared agents group; individual users are added at runtime
RUN groupadd -f agents

# Agents must not have sudo access regardless of group membership
RUN mkdir -p /etc/sudoers.d && \
    echo '%agents ALL=(ALL) !ALL' > /etc/sudoers.d/deny-agents && \
    chmod 440 /etc/sudoers.d/deny-agents

# Shared workspace for inter-agent artifact exchange (SwarmKit ArtifactStore).
# The setgid bit ensures new files inherit the agents group.
RUN mkdir -p /home/shared && \
    chown root:agents /home/shared && \
    chmod 2775 /home/shared

# Install Claude Code and the Agent SDK globally against the system Node install.
# The symlink makes node_modules discoverable at the expected path.
RUN npm install -g @anthropic-ai/claude-code @anthropic-ai/claude-agent-sdk && \
    ln -s /usr/lib/node_modules /usr/local/bin/node_modules

# Install nvm system-wide so agents can pin their own Node versions independently
# of the system Node used by Claude Code.
ENV NVM_DIR=/usr/local/share/nvm
RUN mkdir -p "$NVM_DIR" && \
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash && \
    . "$NVM_DIR/nvm.sh" && \
    nvm install --lts && \
    nvm alias default lts/* && \
    chmod -R a+rX "$NVM_DIR"

# Bake in config trees — these are consumed at runtime by management scripts
COPY config/personas/ /etc/agent-personas/
COPY config/skills/ /etc/agent-skills/
COPY config/skel/ /etc/skel/
COPY config/profile.d/ /etc/profile.d/
RUN chmod +x /etc/profile.d/*.sh

# API keys: if a static global.env was baked in, rename it so the boot-time
# sync script can merge it with environment-variable overrides.
COPY config/api-keys/ /etc/agent-api-keys/
RUN if [ -f /etc/agent-api-keys/global.env ]; then \
    mv /etc/agent-api-keys/global.env /etc/agent-api-keys/global.env.static; \
    fi && \
    chmod 755 /etc/agent-api-keys

# Systemd unit files
COPY config/systemd/ /etc/systemd/system/

# Management and agent runner scripts — Dockerfile COPY makes them executable
# via chmod rather than relying on source file permissions
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh /usr/local/bin/*.mjs

# Store journald logs persistently in /var/log/journal so they survive
# container restarts and are visible from the host bind mount.
RUN mkdir -p /etc/systemd/journald.conf.d && \
    printf '[Journal]\nStorage=persistent\n' > /etc/systemd/journald.conf.d/persistent.conf

# Custom smtpd config (may include a static aliases file)
COPY config/smtpd/ /etc/smtpd/

# Configure OpenSMTPD for local Maildir delivery only.
# Binding to 127.0.0.1 explicitly avoids IPv4/IPv6 resolution races under
# QEMU/Rosetta emulation. Maildir format (one file per message) enables
# inotify-based processing without polling.
RUN printf 'table aliases file:/etc/smtpd/aliases\nlisten on 127.0.0.1 port 25\naction "local" maildir alias <aliases>\nmatch from local for local action "local"\n' > /etc/smtpd/smtpd.conf && \
    touch /etc/smtpd/aliases && \
    mkdir -p /var/spool/smtpd/{offline,purge,temporary,incoming,queue,corrupt} && \
    chmod 711 /var/spool/smtpd && \
    chmod 700 /var/spool/smtpd/{purge,temporary,incoming,queue,corrupt} && \
    chmod 770 /var/spool/smtpd/offline && \
    chown smtpq:root /var/spool/smtpd/{purge,temporary,incoming,queue,corrupt} && \
    chown root:smtpq /var/spool/smtpd/offline

# smtpd.service drop-in: run via a wrapper script in foreground (Type=simple).
# Direct exec of /usr/bin/smtpd exits 255 with 0B memory usage under
# Docker + cgroup2 + Rosetta. A shell wrapper sidesteps this. Also drops
# the Requires=network-online.target dependency which is masked in Docker.
RUN mkdir -p /etc/systemd/system/smtpd.service.d && \
    printf '[Unit]\nRequires=\nAfter=basic.target\n\n[Service]\nType=simple\nExecStart=\nExecStart=/usr/local/bin/start-smtpd.sh\n' \
    > /etc/systemd/system/smtpd.service.d/override.conf && \
    printf '#!/bin/sh\nrm -f /var/run/smtpd.sock\nexec /usr/bin/smtpd -d -f /etc/smtpd/smtpd.conf\n' \
    > /usr/local/bin/start-smtpd.sh && \
    chmod +x /usr/local/bin/start-smtpd.sh

# Point s-nail at the local sendmail binary so bare usernames work as
# recipients (the smtp:// MTA mode requires full addresses).
# The folder setting lets +shortcut paths resolve relative to ~/Maildir.
RUN printf 'set sendwait\nset mta=/usr/sbin/sendmail\nset hostname=localhost\nset folder=Maildir\n' > /etc/mail.rc

# Mask units that cause boot hangs inside Docker:
#
# systemd-networkd-wait-online: waits up to ~2 minutes for network
#   interfaces that Docker already manages, blocking multi-user.target
#   and therefore all agent services.
#
# systemd-firstboot: runs Before=basic.target on every start because the
#   container's root filesystem is ephemeral (ConditionFirstBoot=yes).
#   With a TTY attached it hangs waiting for interactive input, preventing
#   basic.target from being reached. Its job (locale, timezone, hostname)
#   is either inherited from Docker or irrelevant after a restart.
#
#   Alternative (pre-seed instead of mask):
#     RUN systemd-firstboot --locale=C.UTF-8 --timezone=UTC --hostname=gaslite --root-shell=/bin/bash
RUN systemctl mask systemd-networkd-wait-online.service && \
    systemctl mask systemd-firstboot.service

# Enable services that must run at boot
RUN systemctl enable api-keys-sync.service && \
    systemctl enable agent-manager.service && \
    systemctl enable smtpd.service && \
    systemctl enable swarm-orchestrator.service

# Tell systemd it's running inside a container
ENV container=docker

VOLUME ["/home"]

# Confirm the boot sequence completed and the mail daemon is reachable
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD systemctl is-active basic.target && systemctl is-active smtpd.service

# SIGRTMIN+3 is systemd's clean shutdown signal
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/lib/systemd/systemd"]
