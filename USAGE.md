# Quick Start Guide

Day-to-day operations for the agent hosting system. All commands are driven through `make` targets.

## Prerequisites

- Docker and Docker Compose installed on the host
- Network access to Arch Linux package mirrors (required for builds)
- At least one LLM provider API key (Anthropic or another supported provider)

## First-Time Setup

### 1. Build and boot

```bash
make build
make up
```

This builds the Arch Linux image and starts the container with systemd as the init process.

### 2. Create your first agent

```bash
make create-agent NAME=alice
```

This provisions a Linux user `alice`, populates their home directory from the skeleton template, and starts the `agent@alice.service` systemd service.

To assign a specialist persona at creation time:

```bash
make create-agent NAME=bob PERSONA=coder
```

See all available personas with:

```bash
make list-personas
```

Available personas include: `base` (default, applied to all agents), `coder`, `researcher`, `reviewer`, and more.

### 3. Supply an API key

Agents require an API key to call LLMs. The simplest approach is to export the key on the host before starting the container:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
make restart
```

To assign a key to a specific agent:

```bash
make set-api-key NAME=alice KEY=ANTHROPIC_API_KEY=sk-ant-...
```

A key can also be provided at agent creation time:

```bash
make create-agent NAME=alice API_KEY=ANTHROPIC_API_KEY=sk-ant-...
```

### 4. Verify agents are running

```bash
make list-agents
```

### 5. Follow agent logs

```bash
make agent-logs NAME=alice
```

Tails the systemd journal for `agent@alice.service`. Press Ctrl+C to stop.

## Daily Operations

### Container Management

| Command | Description |
|---|---|
| `make build` | Build the Docker image |
| `make up` | Start the container |
| `make down` | Stop and remove the container |
| `make restart` | Restart the container |
| `make shell` | Open a root shell inside the container |
| `make logs` | Tail container logs |
| `make clean` | Remove the image (home directories are preserved) |

### Managing Agents

The container must be running (`make up`) for all agent commands.

| Command | Description |
|---|---|
| `make create-agent NAME=alice` | Create an agent with the base persona |
| `make create-agent NAME=alice PERSONA=coder` | Create an agent with a specialist persona |
| `make remove-agent NAME=alice` | Remove an agent and stop its service |
| `make update-agent NAME=alice PERSONA=reviewer` | Switch an agent to a different persona |
| `make list-agents` | List all agents with their service status |
| `make list-personas` | List all available personas |
| `make agent-logs NAME=alice` | Tail an agent's service logs |
| `make agent-shell NAME=alice` | Open a shell as the agent user |

### Inter-Agent Mail

```bash
make mail TO=alice MSG="Check the auth module"
make mail TO=alice FROM=bob MSG="Review my changes" SUBJECT="Code review"
```

### API Key Management

| Command | Description |
|---|---|
| `make set-api-key NAME=alice KEY=ANTHROPIC_API_KEY=sk-...` | Set an API key for an agent |
| `make get-api-keys NAME=alice` | Show an agent's configured keys (masked) |
| `make remove-api-key NAME=alice KEY=OPENAI_API_KEY` | Remove one specific key |
| `make clear-api-keys NAME=alice` | Remove all keys from an agent |
| `make list-providers` | List all recognized API key provider names |

### Snapshots

Snapshots capture the state of agent home directories over time. They run on the host — the container does not need to be running.

```bash
make snapshot-init            # Initialize the snapshot repository (run once)
make snapshot                 # Take a snapshot with a timestamp message
make snapshot MSG="milestone" # Take a snapshot with a custom message
make snapshot-log             # Show snapshot history
make snapshot-diff            # Show changes since the last snapshot
make snapshot-status          # Summarize what changed since the last snapshot
```

## Customizing Configuration

All configuration files live under `config/` and are baked into the image at build time. After editing anything in `config/`, rebuild and restart:

```bash
make build && make restart
```

- **`config/skel/`** — Template files placed in each new agent's home directory. Changes take effect for agents created after the next rebuild.
- **`config/profile.d/`** — Shell scripts executed for all users at login. Use these for global environment variables and PATH additions.
- **`config/personas/`** — Agent persona definitions. Add a new `.md` file to introduce a new persona.
- **`config/api-keys/`** — Templates for global API key configuration.
- **`config/systemd/`** — Systemd service template governing agent lifecycle and resource limits.

## Troubleshooting

### Build fails with network errors

The build fetches packages from Arch Linux mirrors. The build host must have internet access.

### Configuration changes have no effect

Files under `config/` and `scripts/` are copied into the image at build time. A rebuild is required for changes to take effect:

```bash
make build && make restart
```

### Build fails on Apple Silicon or other ARM hosts

The Arch Linux base image targets `amd64` only. Docker automatically uses QEMU emulation on ARM hosts via the `platform: linux/amd64` setting in `docker-compose.yml`. Ensure QEMU or Rosetta emulation is enabled in Docker Desktop.

### An agent's service won't start

Inspect the service logs to see what failed:

```bash
make agent-logs NAME=alice
```

Then open a root shell for deeper inspection:

```bash
make shell
systemctl status agent@alice.service
```

### Viewing all available Make targets

```bash
make help
```

Or just run `make` with no arguments.

## Further Reading

- `README.md` — Full project overview, architecture notes, and security model
- `config/README.md` — Configuration reference for all files under `config/`
- `scripts/README.md` — Script documentation with argument reference and examples
