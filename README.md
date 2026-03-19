# gaslite

A Docker-based multi-user hosting environment for autonomous Claude Code agents running on Arch Linux.

## What's Included

- Arch Linux base image, always current
- Agent home directories bind-mounted from `./home` on the host
- System logs exported to `./log` for external inspection (journald, smtpd)
- Event-driven Maildir delivery via inotify — no polling delay when mail arrives
- Configurable `/etc/skel` templates for new agent home directories
- Global environment customization via `/etc/profile.d` scripts
- Systemd as the container init system
- Development toolchain: git, gh (GitHub CLI), python, node (system + nvm), base-devel (gcc, make), curl, wget, jq, ripgrep, fd, tree, openssh, unzip
- Node Version Manager (nvm) installed system-wide with LTS pre-installed
- Multi-provider LLM API key management, both global and per-agent
- Supported providers: Anthropic, OpenAI, Google, Mistral, and many others
- Local mail system for inter-agent communication (opensmtpd + s-nail + inotify-tools)

## Directory Structure

```
.
├── Dockerfile              # Main Dockerfile using archlinux:latest
├── docker-compose.yml      # Docker Compose configuration
├── Makefile                # Convenience targets for container and agent management
├── home/                   # Persistent agent home directories (mounted as /home)
├── log/                    # System logs from container (mounted as /var/log)
│   └── journal/            # Systemd journal (persistent agent service logs)
├── config/
│   ├── api-keys/          # API key configuration (copied to /etc/agent-api-keys)
│   │   ├── global.env.template  # Template for global API keys
│   │   └── .gitignore           # Prevents committing actual keys
│   ├── personas/          # Agent persona definitions (copied to /etc/agent-personas)
│   │   ├── base.md              # Base persona (applied to all agents)
│   │   ├── coder.md             # Software development specialist
│   │   ├── researcher.md        # Research and information gathering
│   │   └── ...                  # 11 more specialist personas
│   ├── skills/            # Skill packs (copied to /etc/agent-skills)
│   │   ├── _universal/          # Skills installed to every agent
│   │   │   ├── task-workflow/   # Check ready tasks, claim, work, complete
│   │   │   ├── artifact-sharing/# Produce/consume shared files
│   │   │   ├── report-results/  # Write good result summaries
│   │   │   └── agent-communication/ # Discover team, send mail, check inbox
│   │   ├── coder/               # Skills for coder persona
│   │   ├── researcher/          # Skills for researcher persona
│   │   └── ...                  # 11 more persona skill packs
│   ├── smtpd/             # OpenSMTPD configuration (copied to /etc/smtpd)
│   │   └── aliases.static       # Custom per-agent mail aliases
│   ├── skel/              # Files copied to /etc/skel (template for new users)
│   │   ├── .bashrc        # Default bash configuration
│   │   ├── .bash_profile  # Default bash login configuration
│   │   ├── .gitconfig     # Default git configuration (defaultBranch, editor)
│   │   ├── CLAUDE.md      # Default operating instructions for agents
│   │   ├── agents.md      # Agent persona configuration template
│   │   ├── TODO.md        # Starter task list for agents
│   │   ├── MEMORY.md      # Starter persistent memory file
│   ├── profile.d/         # Files copied to /etc/profile.d (global environment)
│   │   ├── agent-env.sh   # Global agent environment setup
│   │   └── nvm.sh         # Loads nvm (Node Version Manager) for all users
│   └── systemd/           # Systemd service definitions
│       ├── agent@.service          # Per-agent service template
│       ├── mail-watcher@.service   # Per-agent Maildir watcher (non-Docker deployments)
│       ├── agent-manager.service   # Boot-time reconciliation service
│       └── api-keys-sync.service   # Boot-time API key sync service
├── presets/               # Workflow preset library (declarative swarm configs)
│   ├── codebase-audit.json     # Security + quality audit
│   ├── content-pipeline.json   # Content creation pipeline
│   ├── bug-triage.json         # Bug investigation → fix → verify → postmortem
│   ├── feature-build.json      # Spec → design → implement → review → docs
│   ├── security-hardening.json # Scan → threat model → parallel fixes → report
│   ├── api-design.json         # Requirements → design → implement → test → docs
│   ├── data-pipeline.json      # Ingest → validate → analyze → report
│   ├── project-kickoff.json    # Design → scaffold+CI → tests → readme
│   ├── migration-plan.json     # Assess → research → migrate → test → guide
│   └── incident-response.json  # Triage → diagnose → hotfix → verify → postmortem
├── docs/                  # Technical reference documentation
│   └── systemd-cgroup-docker-compat.md  # systemd + cgroup v2 + Docker Desktop research
├── shared/                # Shared artifacts directory (mounted as /home/shared)
├── tui/                   # Interactive TUI (Node.js + Ink, host-side only)
│   ├── package.json       # Dependencies (ink, react)
│   ├── cli.mjs            # Entry point
│   ├── app.mjs            # Root component
│   ├── components/        # UI components (Prompt, Output, StatusBar, Banner)
│   └── lib/               # Logic (commands, executor, container, completions)
├── cli.mjs                # Root-level TUI wrapper (runs tui/cli.mjs)
└── scripts/               # Management scripts (copied to /usr/local/bin)
    ├── create-agent.sh    # Create a new agent user
    ├── update-agent.sh    # Update an agent's persona
    ├── remove-agent.sh    # Remove an agent user
    ├── list-agents.sh     # List agents and their status
    ├── manage-api-keys.sh # Manage per-agent API keys
    ├── soft-reset.sh      # Remove all agents and clear logs
    ├── send-mail.sh       # Send mail to an agent user or alias
    ├── mail-watcher.sh    # inotify-based Maildir watcher (per-agent)
    ├── sync-aliases.sh    # Regenerate mail aliases from agents group
    ├── snapshot-agents.sh # Snapshot agent state (host-only)
    ├── load-preset.sh     # Compile a preset JSON into running agents + tasks
    ├── task.sh            # DAG task board (add/list/ready/update/get/graph)
    ├── artifact.sh        # Shared artifact registry (register/list/get/read)
    ├── swarm-orchestrator.sh  # Central DAG coordinator
    ├── stop-swarm.sh      # Cascading cancellation of all agents
    ├── check-health.sh    # Heartbeat-based health monitoring
    ├── swarm-status.sh    # Result aggregation (tasks + health + costs)
    ├── agent-loop.mjs     # Single agentic work cycle (Claude Agent SDK)
    ├── run-agent.sh       # Agent entrypoint (run by systemd)
    ├── agent-manager.sh   # Boot-time service reconciliation
    ├── sync-api-keys.sh   # Boot-time API key environment sync
    └── test-systemd-services.sh  # Verify systemd service management works
```

## Usage

### Getting Started

Using Docker Compose:
```bash
# Build the image
docker-compose build

# Start the container
docker-compose up -d

# Open a shell inside the container
docker-compose exec gaslite /bin/bash

# Stop the container
docker-compose down
```

Using Docker directly:
```bash
# Build the image
docker build -t arch-dev .

# Run the container with home directory mounted
docker run -it -v $(pwd)/home:/home/user arch-dev
```

### Agent Management Scripts

The `scripts/` directory contains management scripts installed to `/usr/local/bin/` inside the container. Full documentation is in [`scripts/README.md`](scripts/README.md).

These scripts work **from the host** or inside the container — they detect their environment automatically and proxy through `docker exec` when called from outside.

**From the host (direct):**
```bash
./scripts/create-agent.sh alice --persona coder
./scripts/update-agent.sh alice --persona researcher
./scripts/list-agents.sh
./scripts/remove-agent.sh alice --keep-home
```

**From the host (via Make):**
```bash
make create-agent NAME=alice
make update-agent NAME=alice PERSONA=researcher
make list-agents
make remove-agent NAME=alice
```

**Inside the container:**
```bash
create-agent.sh alice
update-agent.sh alice --persona researcher
list-agents.sh
remove-agent.sh alice
```

To target a container other than `gaslite`, set `AGENT_HOST_CONTAINER`:
```bash
AGENT_HOST_CONTAINER=my-container ./scripts/create-agent.sh alice
```

**Stream agent logs:**
```bash
make agent-logs NAME=alice
```
Follows the systemd journal for the specified agent's service.

**Open a shell as an agent:**
```bash
make agent-shell NAME=alice
```

**Send mail to an agent or group:**
```bash
# From root (default sender)
make mail TO=alice MSG="Please check the build logs"

# Broadcast to all agents via group alias
make mail TO=all MSG="Team standup in 5 minutes"

# Send on behalf of another agent
make mail TO=alice FROM=bob MSG="Can you review my PR?"

# With an explicit subject
make mail TO=alice FROM=bob SUBJECT="Code Review" MSG="PR #42 is ready"
```

### Mail Aliases

Mail aliases are kept in sync automatically as agents are created or removed:

- **`all`** — delivers to every registered agent
- **`<persona>-all`** — delivers to all agents of a given persona (e.g., `coder-all`, `manager-all`)

```bash
# Send to every agent
make mail TO=all MSG="Team standup in 5 minutes"

# Send to all coders
make mail TO=coder-all MSG="Please review the new coding standards"
```

Custom aliases (e.g., `devs: alice, bob`) can be defined in `config/smtpd/aliases.static`. After editing, rebuild the image and run:
```bash
make sync-aliases
```

### API Key Management

Both global (all-agent) and per-agent API key configuration are supported.

#### Global API Keys (All Agents)

Option 1 — pass from the host environment (recommended):
```bash
export ANTHROPIC_API_KEY=sk-ant-xxx
export OPENAI_API_KEY=sk-xxx
docker-compose up -d
```

Option 2 — bake into the image (for private images only):
```bash
cp config/api-keys/global.env.template config/api-keys/global.env
# Edit global.env with your keys
docker-compose build
```

#### Per-Agent API Keys

Assign a key at creation time:
```bash
make create-agent NAME=alice API_KEY=ANTHROPIC_API_KEY=sk-ant-xxx
```

Or manage keys on an existing agent:
```bash
make set-api-key NAME=alice KEY=ANTHROPIC_API_KEY=sk-ant-xxx
make set-api-key NAME=alice KEY=OPENAI_API_KEY=sk-xxx
make get-api-keys NAME=alice
make remove-api-key NAME=alice KEY=OPENAI_API_KEY
make clear-api-keys NAME=alice
```

Per-agent keys take precedence over global keys. See [`scripts/README.md`](scripts/README.md) for full documentation.

#### Supported Providers

Anthropic, OpenAI, Google/Gemini, Mistral, Cohere, Groq, Together.ai, Fireworks.ai, Perplexity, Replicate, Hugging Face, AWS Bedrock, Azure OpenAI, GitHub (`GITHUB_TOKEN` / `GH_TOKEN`).

Run `make list-providers` to print all recognized provider variable names.

#### How Agents Run

Each agent runs as a systemd service (`agent@<username>.service`) created by `create-agent.sh`. A companion `mail-watcher.sh` process (launched via `nohup su`) monitors `~/Maildir/new/` using inotify and logs incoming deliveries. The agent loop uses `inotifywait` to wake immediately on new mail rather than waiting for the next scheduled cycle. On each cycle, `agent-loop.mjs` (powered by the Claude Agent SDK) checks mail, processes tasks from `TODO.md`, writes results, and updates `MEMORY.md`. Cycles run every 5 minutes by default (configurable via `AGENT_CYCLE_INTERVAL`), but new mail triggers an immediate cycle. Agent stdout/stderr go to the systemd journal; mail watcher output goes to `/var/log/mail-watcher-<username>.log`.

At boot, `agent-manager.sh` walks every user in the `agents` group — enabling their systemd services, launching mail watchers via `nohup su`, and migrating any legacy mbox mail into Maildir format.

### Workflow Presets

Presets are declarative JSON files describing a full swarm: agents, a task dependency graph (DAG), and optional kickoff messages. The `load-preset.sh` compiler translates them into calls to the underlying shell primitives (`create-agent.sh`, `task.sh add`, `send-mail.sh`). The compiler is a thin translation layer with no business logic of its own.

**List available presets:**
```bash
make list-presets
```

**Load a preset:**
```bash
# Preview what would happen (no changes made)
make load-preset FILE=presets/bug-triage.json DRY_RUN=1

# Execute (creates agents, tasks, and sends kickoff mail)
make load-preset FILE=presets/bug-triage.json

# Skip agents that already exist
make load-preset FILE=presets/feature-build.json SKIP_EXISTING=1
```

**Variable substitution:** Presets use `${VAR:-default}` placeholders in task descriptions and mail bodies. Set them as environment variables before loading. The script prints which defaults are being used and errors on required variables that have no default:
```bash
BUG_TITLE="Login timeout" BUG_DESCRIPTION="Users report 30s hangs" \
  make load-preset FILE=presets/bug-triage.json

# Inspect which variables a preset declares
load-preset.sh presets/bug-triage.json --check-vars
```

**TUI interactive prompting:** When loading a preset through the TUI, each variable is prompted for before loading begins. Press Enter to accept the default. Variables can also be provided inline:
```
load-preset feature-build FEATURE_NAME="Dark mode"
```

**Shipped presets (10):**

| Preset | Agents | DAG Shape | Problem Solved |
|--------|--------|-----------|----------------|
| `codebase-audit` | 5 | fan-out | Security + quality audit |
| `content-pipeline` | 4 | linear | Content creation pipeline |
| `bug-triage` | 4 | linear | Bug investigation → fix → verify → postmortem |
| `feature-build` | 5 | linear + revision | Spec → design → implement → review → docs |
| `security-hardening` | 4 | fan-out merge | Scan → threat model → parallel fixes → report |
| `api-design` | 5 | linear | Requirements → design → implement → test → docs |
| `data-pipeline` | 4 | fan-out merge | Ingest → validate → analyze → report |
| `project-kickoff` | 4 | fan-out merge | Design → scaffold+CI → tests → readme |
| `migration-plan` | 5 | fan-out merge | Assess → research → migrate → test → guide |
| `incident-response` | 4 | diamond | Triage → diagnose → hotfix → verify → postmortem |

**TUI commands:**
```
list-presets                          # List all presets with descriptions
load-preset presets/bug-triage.json   # Load a preset (prompts for variables)
load-preset bug-triage TOPIC="AI"     # Load with inline variable overrides
preset-info presets/bug-triage.json   # Show agents, tasks, and variables
```

### Skill Packs

Skill packs give agents procedural knowledge from day one. Each skill is a `SKILL.md` file in the Claude Code format (YAML frontmatter + markdown instructions) with real, runnable commands and step-by-step procedures.

**How it works:**
- `config/skills/_universal/` — installed into every agent's `~/.claude/skills/`
- `config/skills/<persona>/` — installed only for agents whose persona matches (e.g., coder agents get `config/skills/coder/`)
- Skills are **copied, not symlinked** — agents can extend or modify them after creation
- **Existing skills are never overwritten** — agent customizations are preserved across re-runs

**Universal skills (4)** — every agent receives these:
- `task-workflow` — Check ready tasks, claim, work, complete cycle
- `artifact-sharing` — Produce and consume shared files via `artifact.sh`
- `report-results` — Write structured result summaries
- `agent-communication` — Discover teammates, send/check mail

**Persona skills (23)** — installed based on persona:
- **coder**: project-setup, test-and-validate, focused-pr, code-refactor
- **researcher**: structured-research, source-evaluation
- **architect**: system-design, codebase-survey
- **security**: vulnerability-scan, dependency-audit
- **qa**: test-plan, regression-check
- **writer**: technical-writing, changelog-generation
- **editor**: editorial-review
- **reviewer**: code-review
- **planner**: task-decomposition
- **analyst**: data-analysis, metrics-report
- **devops**: dockerfile-authoring, ci-pipeline
- **manager**: delegation-workflow
- **ops**: triage-routing

**Verification:**
```bash
# After creating a coder agent:
make agent-shell NAME=alice
ls ~/.claude/skills/
# → task-workflow/ artifact-sharing/ report-results/ agent-communication/
#   project-setup/ test-and-validate/ focused-pr/ code-refactor/
```

### Interactive TUI

An interactive command prompt for managing the system, similar in feel to Claude Code. Built with Node.js and Ink.

**Setup:**
```bash
make install-tui   # Install dependencies (first time only)
```

**Run:**
```bash
make tui           # or: node cli.mjs
```

**Available commands inside the TUI:**

| Command | Description |
|---------|-------------|
| `build` | Build the Docker image |
| `up` / `down` / `restart` | Container lifecycle |
| `container-logs` | View container logs |
| `clean` | Stop container, remove image |
| `reset` | Full reset (hint — requires `make reset`) |
| `status` | Show container status |
| `list` | List agents and their status |
| `create alice --persona coder` | Create a new agent |
| `create alice --instructions "Focus on tests"` | Create with custom instructions |
| `remove alice` | Remove an agent |
| `logs alice` | Stream agent logs (Ctrl+C to stop) |
| `soft-reset` | Remove all agents and clear logs |
| `personas` | List available personas |
| `set-key alice ANTHROPIC_API_KEY=sk-xxx` | Set API key |
| `clear-keys alice` | Remove all API keys from an agent |
| `providers` | List known API key provider names |
| `mail alice "Hello"` | Send mail to an agent or alias |
| `read-mail alice` | Read an agent's mailbox |
| `sync-aliases` | Regenerate mail aliases |
| `snapshot-init` | Initialize the snapshot repository |
| `snapshot "my note"` | Take a state snapshot |
| `snapshot-log` / `snapshot-diff` / `snapshot-status` | Snapshot history and changes |
| `swarm-status` | Show task board, health, costs, and events |
| `swarm-stop` / `swarm-stop --reason "bug"` | Stop all agents and orchestrator |
| `health` | Check agent heartbeat health |
| `task-add "Build engine" alice` | Add a task to the shared board |
| `task-list` / `task-list --owner alice` | List tasks (optionally filtered) |
| `task-ready` | List tasks ready to start |
| `task-update task-abc completed` | Update a task's status |
| `task-graph` | Show task dependency graph |
| `artifact-list` | List shared artifacts |
| `artifact-register reports/out.csv` | Register a shared artifact |
| `artifact-get reports/out.csv` | Get metadata for an artifact |
| `list-presets` | List available workflow presets |
| `load-preset presets/bug-triage.json` | Load a workflow preset |
| `preset-info presets/bug-triage.json` | Show preset details (agents, tasks, variables) |
| `help` | Show all commands |

Tab completion is available for commands, agent names, and persona names. Arrow keys navigate command history.

### Customizing Configuration

#### Modifying /etc/skel Templates

Files under `config/skel/` become the template for every new agent's home directory:
- `config/skel/.bashrc` — Default bash configuration for interactive shells
- `config/skel/.bash_profile` — Default bash login script
- Add any additional files that new agents should start with

After editing, rebuild:
```bash
docker-compose build
```

#### Modifying /etc/profile.d Scripts

Scripts in `config/profile.d/` run for all users at login and are the right place for global environment variables:
- `config/profile.d/agent-env.sh` — Custom global environment settings
- Add more `.sh` files for additional global configuration

After editing, rebuild:
```bash
docker-compose build
```

#### Systemd User Services

To give agents pre-configured systemd user services:
1. Add service files to `config/skel/.config/systemd/user/`
2. Enable them from `config/skel/.bash_profile` or `config/skel/.bashrc`
3. Or add a script in `config/profile.d/` that sets up systemd user services

### Home Directory Persistence

The `./home` directory is bind-mounted as `/home` inside the container. Files written by agents persist to the host filesystem automatically — nothing needs to be copied out.

### Observing Agents From the Host

Several container paths are bind-mounted to the host so agent activity can be monitored without entering the container.

| Host path | Container path | Contents |
|-----------|---------------|----------|
| `./home` | `/home` | Agent home directories, including `.agent.log` and `Maildir/` per agent |
| `./log` | `/var/log` | System logs — journald, smtpd, and other service logs |
| `./log/journal` | `/var/log/journal` | Systemd journal (binary) — all agent service stdout/stderr |
| `./shared` | `/home/shared` | Shared artifacts registered via `artifact.sh` for inter-agent use |

**Reading agent service logs from the host:**
```bash
# Logs for a specific agent (requires systemd on the host)
journalctl --directory=./log/journal -u agent@alice.service

# Follow all agent logs in real time
journalctl --directory=./log/journal -u 'agent@*' -f

# Or read per-agent log files directly
cat ./home/alice/.agent.log
```

**Reading agent mail from the host:**
```bash
# List delivered messages (Maildir format — one file per message)
ls ./home/alice/Maildir/cur/

# Read a specific message
cat ./home/alice/Maildir/cur/<filename>

# Count messages still waiting to be processed
ls ./home/alice/Maildir/new/ 2>/dev/null | wc -l
```

**Reading system logs:**
```bash
# All journal entries
journalctl --directory=./log/journal

# Mail system activity
journalctl --directory=./log/journal -u smtpd.service
```

### Snapshotting Agent State

Agent output — home directories, logs, mail — can be version-controlled independently from the project source. The snapshot system uses a separate git repository (`.agent-snapshots/`) with its own `GIT_DIR`, so it never interferes with the main repo. The snapshot directory is not mounted into the container, so agents cannot access it.

**Setup:**
```bash
make snapshot-init
```

**Taking snapshots:**
```bash
make snapshot                           # Snapshot with a timestamp message
make snapshot MSG="alice finished task"  # Snapshot with a custom message
```

**Reviewing history:**
```bash
make snapshot-status    # Summarize changes since last snapshot
make snapshot-diff      # Full diff since last snapshot
make snapshot-log       # Full snapshot history
```

**What gets tracked:**
- `home/` — Agent home directories (work output, per-agent logs, config, Maildir)
- `log/` — System logs (text logs only; binary journal files are excluded)

See [`scripts/README.md`](scripts/README.md) for full documentation of `snapshot-agents.sh`.

## Notes

- Agent users are unprivileged members of the `agents` group with no sudo access. Unix permissions (home directories are mode 700) prevent agents from writing outside their own home. Only root can install packages or modify the system. Systemd security hardening directives (NoNewPrivileges, ProtectSystem, PrivateTmp, CapabilityBoundingSet, RestrictAddressFamilies, resource limits, etc.) are commented out by default because they cause silent service failures inside Docker containers (cgroup delegation, overlay2 mount conflicts, seccomp layering). The Docker container boundary provides equivalent isolation. Uncomment them in `config/systemd/agent@.service` for non-Docker deployments.
- `systemd-networkd-wait-online.service` is masked in the Docker image because Docker manages networking externally. Without the mask, this service delays `multi-user.target` by up to 2 minutes waiting for network connectivity, which blocks all agent services from starting.
- `systemd-firstboot.service` is masked because it runs `Before=basic.target` on every container start (`ConditionFirstBoot=yes`, since the root filesystem is ephemeral) and blocks waiting for interactive input when a TTY is attached, which prevents `basic.target` and all dependent services from reaching active state.
- The agent home directory tree is persisted to the host via the `./home` bind mount. Configuration files edited in the repository take effect after rebuilding the image.
- Systemd requires privileged mode, which is already set in `docker-compose.yml`.
- The Arch Linux base image is `linux/amd64` only. Docker uses QEMU emulation automatically on ARM hosts (e.g., Apple Silicon Macs) via the `platform: linux/amd64` setting in `docker-compose.yml`.
