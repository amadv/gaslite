# CLAUDE.md

Guidelines for working on the gaslite codebase.

## Project Overview

gaslite is a Docker-based multi-user hosting system for autonomous Claude Code agents, built on Arch Linux. Each agent runs in an isolated environment under a dedicated Linux user account, with systemd managing the service lifecycle and strict security policies enforced at the OS level.

**This is an infrastructure/DevOps project, not an application.** Stability, security, and simplicity take priority over new features.

## Project Structure

```
.
├── Dockerfile                  # Docker image definition (Arch Linux + systemd)
├── docker-compose.yml          # Container orchestration (privileged, systemd init)
├── Makefile                    # Host-side convenience targets
├── README.md                   # Main project documentation
├── USAGE.md                    # Quick start guide
├── home/                       # Persistent agent home directories (mounted as /home, includes ~/Maildir/)
├── log/                        # System logs from container (mounted as /var/log)
│   └── journal/                # Systemd journal (persistent agent service logs)
├── config/
│   ├── README.md               # Configuration documentation
│   ├── api-keys/               # API key configuration -> /etc/agent-api-keys
│   ├── skel/                   # Template for new agent homes -> /etc/skel
│   ├── profile.d/              # Global environment scripts -> /etc/profile.d
│   ├── personas/               # Agent persona definitions -> /etc/agent-personas
│   └── systemd/                # Systemd service files
├── docs/                       # Technical reference documentation
│   └── systemd-cgroup-docker-compat.md  # systemd + cgroup v2 + Docker research
└── scripts/
    ├── README.md               # Scripts documentation
    ├── create-agent.sh         # Create agent user (with optional --persona, --instructions, --api-key)
    ├── update-agent.sh         # Update agent persona at runtime
    ├── remove-agent.sh         # Remove agent user
    ├── list-agents.sh          # List agents and status
    ├── manage-api-keys.sh      # Manage per-agent API keys
    ├── snapshot-agents.sh      # Snapshot agent state (host-only)
    ├── run-agent.sh            # Agent entrypoint (called by systemd)
    ├── agent-manager.sh        # Boot-time service reconciliation
    ├── sync-api-keys.sh        # Boot-time API key environment sync
    └── test-systemd-services.sh # Verify systemd service management works
```

## Documentation Requirements

**All documentation must stay accurate and current.** Before committing any change, update every doc that the change affects.

### When to Update What

| What changed | Update these docs |
|---|---|
| Any script in `scripts/` | `scripts/README.md` — update usage, arguments, behavior, and examples |
| Makefile targets | `scripts/README.md` (Makefile Targets section), `README.md` (Agent Management Scripts section), and `tui/lib/commands.mjs` + `tui/lib/completions.mjs` (TUI must mirror Make targets) |
| TUI commands (`tui/lib/`) | Makefile (help text) and `README.md` (Interactive TUI section) — every TUI command should have a Make equivalent and vice versa |
| Files in `config/` | `config/README.md` and `README.md` (Directory Structure and Customizing Configuration sections) |
| Persona files in `config/personas/` | `config/README.md` and `README.md` |
| API key configuration in `config/api-keys/` | `config/README.md` and `README.md` (API Key Management section) |
| Dockerfile or docker-compose.yml | `README.md` and `USAGE.md` |
| New top-level files or directories | `README.md` (Directory Structure section) |
| Changes to the build or run process | `README.md` (Usage section) and `USAGE.md` |
| Security model changes | `README.md` (Notes section) |
| This file (CLAUDE.md) | No additional docs needed |

### Make and TUI Parity

Every Makefile target except `tui`, `install-tui`, and `help` must have a matching TUI command in `tui/lib/commands.mjs`. Adding a Makefile target means also adding the TUI command and updating `tui/lib/completions.mjs`. Naming conventions:
- Makefile uses `kebab-case` with `NAME=` variables (e.g., `make create-agent NAME=alice PERSONA=coder`)
- TUI uses shorter `kebab-case` with positional arguments (e.g., `create alice --persona coder`)
- Commands that require `sudo` or interactive input should be `builtin: true` in the TUI with a hint to use `make` instead

### Documentation Standards

- Write concisely and factually. No marketing language or filler.
- Cover what the thing does, how to invoke it, and what arguments it accepts.
- Use realistic examples — agent names like `alice` and `bob` are preferred.
- When a script's behavior changes, update both its section in `scripts/README.md` and any cross-references in `README.md`.
- The directory tree in `README.md` must always match the real file structure. Add or remove entries whenever files are created or deleted.

## Build and Test

```bash
# Build the Docker image
make build

# Start the container
make up

# Open a root shell in the container
make shell

# Create a test agent
make create-agent NAME=testuser

# Verify the agent is listed
make list-agents

# Inspect agent logs
make agent-logs NAME=testuser

# Clean up
make remove-agent NAME=testuser
make down
```

There are no automated tests. Validate changes manually by building the image and exercising the relevant scripts inside the container.

## Key Constraints

### Security Model — Do Not Weaken

- Agents run as unprivileged users in the `agents` group with no sudo access.
- `/usr` and `/boot` are read-only for agents. Unix permissions prevent writing outside an agent's own home directory.
- Each agent gets a private `/tmp`, no Linux capabilities, and restricted address families.
- Memory is capped at 512M and CPU at 50% per agent.
- Home directories are mode 700. The `.claude/` directory is root-owned.
- **Do not grant sudo access, remove capability restrictions, or weaken the systemd security hardening** without explicit approval.

### Systemd Is the Process Manager

- Every agent runs as a systemd service (`agent@<username>.service`).
- `agent-manager.sh` reconciles services at boot time.
- Do not bypass systemd for agent lifecycle management.

### Config Changes Require a Rebuild

- Everything under `config/` and `scripts/` is baked into the image at build time.
- Always remind users to rebuild after modifying these directories.

### Home Directories Are the Only Persistent Storage

- `/home` is a bind mount from the host. Everything else in the container is ephemeral.
- Do not store important data anywhere outside of agent home directories.

## Code Style

### Shell Scripts

- Use `#!/bin/bash` and `set -euo pipefail` at the top of every script.
- Validate all user-supplied input (usernames, flags) before acting on it.
- Use `readonly` for constants.
- Log to both stdout/stderr (captured by journald) and to a log file when appropriate.
- Always quote variable expansions: `"$var"`, never bare `$var`.
- Review existing scripts in `scripts/` for style reference before writing new ones.

### Makefile

- Targets that wrap container commands should use `docker-compose exec`.
- Agent management targets should require `NAME=<value>` where a username is needed.
- Preserve the `## description` help comment on every target for self-documentation.

### Personas

- `base.md` is layered onto every agent. Keep it general-purpose.
- Specialist personas extend the base persona; they do not replace it.
- Every persona **must** have `- **Role**: ...` and `- **Purpose**: ...` lines under an `## Identity` heading. These are extracted by `create-agent.sh` and written to the GECOS field in `/etc/passwd`, which is how agents discover each other's capabilities.
- Each persona should also define its core instructions and expected output conventions.

## Common Patterns

### Adding a New Script

1. Create the script in `scripts/` with the correct shebang and `set -euo pipefail`.
2. The Dockerfile copies all of `scripts/` to `/usr/local/bin/`, so no Dockerfile edit is needed.
3. Add a Makefile target if the script should be reachable from the host.
4. Document the script in `scripts/README.md` using the established format (Usage, Arguments, What it does, Example).
5. Update the `README.md` directory tree and any sections that reference the script.

### Adding a New Persona

1. Create a `.md` file in `config/personas/`.
2. Follow the three-section structure: `## Identity` (with `- **Role**: ...` and `- **Purpose**: ...`), `## Instructions`, `## Output Format`. The Role and Purpose lines are required — `create-agent.sh` extracts them for the GECOS field.
3. Add the new persona to the list in `config/README.md`.
4. No script changes are needed — `create-agent.sh` discovers personas by filename.

### Modifying Agent Service Behavior

1. Edit `config/systemd/agent@.service` for service-level changes (resource limits, security directives, restart policy).
2. Edit `scripts/run-agent.sh` for changes to the runtime loop.
3. Reflect both changes in `scripts/README.md` and `README.md`.

### Managing API Keys

API keys are loaded in two layers at agent startup:
1. **Global keys** from `/etc/agent-api-keys/global.env` (applies to all agents)
2. **Per-agent keys** from `~/.claude/api-keys.env` (overrides global for that agent)

To add support for a new provider:
1. Add the environment variable name to the `KNOWN_PROVIDERS` array in `scripts/manage-api-keys.sh`
2. Add the variable to the `KNOWN_KEYS` array in `scripts/sync-api-keys.sh`
3. Add the environment passthrough in the `docker-compose.yml` environment section
4. Document it in `config/api-keys/global.env.template`
5. Add it to the supported providers list in `config/README.md`

Security: API key files are root-owned and agent-readable (mode 640). Per-agent keys stored in `.claude/` inherit root ownership.
