# Scripts

Management scripts for the multi-user agent hosting system. All scripts in this directory are copied to `/usr/local/bin/` inside the container during the Docker build.

## Running From the Host

The agent management scripts (`create-agent.sh`, `remove-agent.sh`, `list-agents.sh`) detect whether they are running inside the container or on the host. When invoked from the host, they transparently proxy themselves into the running container via `docker exec` — no need to open a shell first.

```bash
# Call scripts directly from the host
./scripts/create-agent.sh alice --persona coder
./scripts/list-agents.sh
./scripts/remove-agent.sh alice

# Or put scripts/ on your PATH
export PATH="$PWD/scripts:$PATH"
create-agent.sh alice
list-agents.sh
```

By default, scripts target the container named `gaslite`. To target a different container, set `AGENT_HOST_CONTAINER`:

```bash
AGENT_HOST_CONTAINER=my-container ./scripts/create-agent.sh alice
```

The Makefile targets and direct container invocation both remain valid alternatives.

## Scripts Overview

| Script | Purpose | Usage |
|--------|---------|-------|
| `create-agent.sh` | Create a new agent user | `create-agent.sh <username> [--persona <name>] [--instructions <text>] [--api-key <KEY>=<val>]` |
| `update-agent.sh` | Update an agent's persona | `update-agent.sh <username> --persona <name>` |
| `remove-agent.sh` | Remove an agent user | `remove-agent.sh <username> [--keep-home]` |
| `list-agents.sh` | List agents and their status | `list-agents.sh` |
| `soft-reset.sh` | Remove all agents and clear logs | `soft-reset.sh [--yes]` |
| `mail-watcher.sh` | inotify-based Maildir watcher (per-agent) | Automatic — launched by `create-agent.sh` / `agent-manager.sh` |
| `manage-api-keys.sh` | Manage per-agent API keys | `manage-api-keys.sh <command> <args>` |
| `send-mail.sh` | Send mail to an agent or alias | `send-mail.sh <recipient> [--from <user>] [--subject <text>] -- <message>` |
| `sync-aliases.sh` | Regenerate mail aliases | `sync-aliases.sh` |
| `snapshot-agents.sh` | Snapshot agent state (host-only) | `snapshot-agents.sh <command> [args]` |
| `load-preset.sh` | Compile a preset JSON into agents + tasks | `load-preset.sh <file.json> [--dry-run] [--skip-existing]` |
| `task.sh` | DAG task board management | `task.sh <add\|list\|ready\|update\|get\|graph> [args]` |
| `artifact.sh` | Shared artifact registry | `artifact.sh <register\|list\|get\|read> [args]` |
| `swarm-orchestrator.sh` | Central DAG coordinator | Automatic — runs as systemd service |
| `stop-swarm.sh` | Cascading cancellation | `stop-swarm.sh [--reason <text>]` |
| `check-health.sh` | Heartbeat-based health monitoring | `check-health.sh` |
| `swarm-status.sh` | Result aggregation | `swarm-status.sh` |
| `agent-loop.mjs` | Single agentic work cycle (Agent SDK) | Automatic — called by `run-agent.sh` |
| `run-agent.sh` | Agent entrypoint (run by systemd) | Automatic — not run manually |
| `agent-manager.sh` | Boot-time service reconciliation | Automatic — runs at container start |
| `sync-api-keys.sh` | Sync env vars to global API keys | Automatic — runs at container start |
| `test-systemd-services.sh` | Verify systemd service management | `test-systemd-services.sh [--verbose]` |

---

## sync-aliases.sh

Rebuilds `/etc/smtpd/aliases` from current group membership. Keeps the `all` group alias up to date, generates per-persona group aliases (e.g., `coder-all`, `manager-all`), and merges in custom aliases from `/etc/smtpd/aliases.static`.

**Usage:**
```bash
# Inside the container
sync-aliases.sh

# From the host via Make
make sync-aliases
```

**Arguments:** None.

**What it does:**
1. Reads all members of the `agents` group
2. Writes the `all` alias delivering to every agent
3. Writes per-persona aliases (`<persona>-all`) for each persona with at least one member
4. Merges custom aliases from `/etc/smtpd/aliases.static` (if the file exists)
5. Writes the result to `/etc/smtpd/aliases`

Called automatically by `create-agent.sh`, `remove-agent.sh`, `agent-manager.sh`, and `soft-reset.sh`. Can be run manually via `make sync-aliases` when needed.

**Example:**
```bash
# After creating alice (coder) and bob (manager), /etc/smtpd/aliases contains:
# all: alice, bob
# coder-all: alice
# manager-all: bob
make sync-aliases
```

---

## create-agent.sh

Provisions a new agent user: creates the Linux account, populates the home directory, configures persona and optional custom instructions, sets up the Maildir structure, and starts the systemd service.

**Usage:**
```bash
# Inside the container
create-agent.sh <username> [--persona <name>] [--instructions <text>] [--api-key <PROVIDER>=<key>]...

# From the host via Make
make create-agent NAME=<username> [PERSONA=<name>] [INSTRUCTIONS="text"] [API_KEY=<PROVIDER>=<key>]
```

**Arguments:**
- `<username>` (required) — Must start with a lowercase letter or underscore, contain only `[a-z0-9_-]`, and be at most 32 characters.
- `--persona <name>` (optional) — Apply a specialist persona (e.g., `coder`, `researcher`).
- `--instructions <text>` (optional) — Custom instructions appended to the agent's `agents.md` under a "Custom Instructions" section.
- `--api-key <PROVIDER>=<key>` (optional) — Set an API key for this agent. Repeatable for multiple keys.

**What it does:**
1. Validates the username format
2. Creates a Linux user with a home directory populated from `/etc/skel`. The GECOS field is set to the persona's role (e.g., `Software Developer (coder)`) so other agents can discover it via `getent passwd`
3. Adds the user to the `agents` group and the persona group (e.g., `coder`), creating the persona group if it does not exist
4. Creates the `~/Maildir/{new,cur,tmp}` directory structure for Maildir delivery
5. Regenerates mail aliases (adds the new user to the `all` and `<persona>-all` aliases)
6. Builds `agents.md` from the base persona + optional specialist persona + optional custom instructions
7. Creates a root-owned `.claude/` directory in the user's home with a default `config.json`
8. Configures git identity (`user.name` from username + persona, `user.email` as `<username>@gaslite`)
9. Pre-populates `~/.ssh/known_hosts` with host keys for github.com and gitlab.com (best-effort; warns if unreachable)
10. Writes per-agent API keys if provided (stored in `.claude/api-keys.env`)
11. Starts the mail watcher process (monitors `~/Maildir/new/` via inotify)
12. Waits for systemd to reach `basic.target` if needed
13. Runs `systemctl daemon-reload` to pick up the new service instance
14. Enables and starts `agent@<username>.service` (blocks until active, or reports failure with journal output and service status)

**Examples:**
```bash
# Create an agent with the default base persona
make create-agent NAME=alice

# Create an agent with a specialist persona
make create-agent NAME=alice PERSONA=coder

# Create an agent with an API key
make create-agent NAME=bob API_KEY=ANTHROPIC_API_KEY=sk-ant-xxx

# Create an agent with custom instructions
make create-agent NAME=carol PERSONA=coder INSTRUCTIONS="Focus on Python backend code"

# Create an agent with both persona and API key (inside container)
create-agent.sh dave --persona researcher --api-key OPENAI_API_KEY=sk-xxx
```

---

## update-agent.sh

Changes an existing agent's persona. Rebuilds `agents.md`, updates the config, and restarts the service so the new persona takes effect immediately.

**Usage:**
```bash
# Inside the container
update-agent.sh <username> --persona <name>

# From the host via Make
make update-agent NAME=<username> PERSONA=<name>
```

**Arguments:**
- `<username>` (required) — The agent to update.
- `--persona <name>` (required) — The new persona to apply. Use `base` to remove any specialist persona and revert to the base persona only.

**What it does:**
1. Confirms the user exists and belongs to the `agents` group
2. Confirms the requested persona exists in `/etc/agent-personas/`
3. Rebuilds `agents.md` from the base persona + the requested specialist persona
4. Updates `.claude/config.json` with the new persona name
5. Restarts `agent@<username>.service` to apply the change (non-blocking)

**Examples:**
```bash
# Switch alice to the researcher persona
make update-agent NAME=alice PERSONA=researcher

# Strip alice's specialist persona, leaving only base
make update-agent NAME=alice PERSONA=base
```

---

## remove-agent.sh

Stops the agent's systemd service and deletes the user account.

**Usage:**
```bash
# Inside the container
remove-agent.sh <username> [--keep-home]

# From the host via Make
make remove-agent NAME=<username>
```

**Arguments:**
- `<username>` (required) — The agent user to remove.
- `--keep-home` (optional) — Preserve `/home/<username>` instead of deleting it.

**What it does:**
1. Stops the mail watcher process (identified via `~/.mail-watcher.pid`)
2. Stops and disables the `agent@<username>.service` systemd service
3. Deletes the Linux user account
4. Removes the home directory including Maildir (unless `--keep-home` is passed)
5. Removes empty persona groups (e.g., deletes the `coder` group if the last coder was just removed)
6. Regenerates mail aliases (removes the user from `all` and `<persona>-all`)

**Example:**
```bash
make remove-agent NAME=alice

# Preserve the home directory for inspection
remove-agent.sh alice --keep-home
```

---

## list-agents.sh

Prints all registered agent users along with their systemd service status and home directory state.

**Usage:**
```bash
# Inside the container
list-agents.sh

# From the host via Make
make list-agents
```

**Arguments:** None.

**Output:**
```
USER                 SERVICE      ACTIVE     HOME
----                 -------      ------     ----
alice                agent@alice.service active     /home/alice (yes)
bob                  agent@bob.service   inactive   /home/bob (yes)
```

---

## soft-reset.sh

Removes every agent user and rotates the systemd journal. The container continues running and is immediately ready for new agents. Mail is removed along with each agent's home directory (stored as Maildir).

**Usage:**
```bash
# Inside the container
soft-reset.sh [--yes]

# From the host via Make
make soft-reset
```

**Arguments:**
- `--yes` / `-y` (optional) — Skip the interactive confirmation prompt. The Makefile target passes this automatically.

**What it does:**
1. Enumerates all users in the `agents` group
2. Calls `remove-agent.sh` for each one (stops service + mail watcher, deletes user and home directory)
3. Regenerates mail aliases (clears the `all` alias)
4. Rotates and vacuums the systemd journal

**Examples:**
```bash
# From the host (no confirmation prompt)
make soft-reset

# Inside the container (interactive confirmation)
soft-reset.sh

# Inside the container (skip confirmation)
soft-reset.sh --yes
```

---

## send-mail.sh

Delivers a message to an agent user or mail alias using the local mail system. Sends as root by default; use `--from` to send as a specific agent.

**Usage:**
```bash
# Inside the container
send-mail.sh <recipient> [--from <user>] [--subject <text>] -- <message>

# From the host via Make
make mail TO=<recipient> MSG="<message>" [FROM=<user>] [SUBJECT="<text>"]
```

**Arguments:**
- `<recipient>` (required) — An existing agent user or a known alias (e.g., `all`, `coder-all`).
- `--from <user>` (optional) — Send as this user rather than root. The command runs the mailer as the specified user via `runuser`.
- `--subject <text>` (optional) — Subject line. Defaults to "Message".
- `-- <message>` (required) — The message body. Use `--` to separate it from option flags, or pass it as the last positional argument.

**What it does:**
1. Validates the recipient is a known user or alias
2. Validates the `--from` user exists (if specified)
3. Delivers the message via the local mail system (s-nail through opensmtpd)
4. If `--from` is given, runs the mailer as that user via `runuser`; otherwise sends as root

**Examples:**
```bash
# Send to alice from root
make mail TO=alice MSG="Please check the build logs"

# Broadcast to all agents
make mail TO=all MSG="Team standup in 5 minutes"

# Send from bob to alice
make mail TO=alice FROM=bob MSG="Hey, can you review my PR?"

# Send with a custom subject
make mail TO=alice FROM=bob SUBJECT="Code Review" MSG="PR #42 is ready for review"

# Inside the container
send-mail.sh alice -- "Hello from root"
send-mail.sh all -- "Broadcast to everyone"
send-mail.sh alice --from bob --subject "Update" -- "Task complete"
```

---

## snapshot-agents.sh

Captures agent runtime state (home directories including Maildir, and text logs) into a dedicated git repository. **Host-only** — refuses to run inside the container.

The snapshot repository lives at `.agent-snapshots/` and uses explicit `--git-dir` / `--work-tree` flags for every git operation, keeping it completely separate from the main source repo. It is not mounted into the container.

**Usage:**
```bash
# From the host
./scripts/snapshot-agents.sh <command> [args]

# Via Make
make snapshot-init
make snapshot
make snapshot MSG="after task 3"
make snapshot-log
make snapshot-diff
make snapshot-status
```

**Commands:**

| Command | Description | Example |
|---------|-------------|---------|
| `init` | Initialize the snapshot repository | `snapshot-agents.sh init` |
| `create` | Take a snapshot (default message: timestamp) | `snapshot-agents.sh create "checkpoint"` |
| `log` | Show snapshot history | `snapshot-agents.sh log -5` |
| `diff` | Show changes since last snapshot | `snapshot-agents.sh diff HEAD~1` |
| `show` | Show a specific snapshot | `snapshot-agents.sh show HEAD` |
| `status` | Summarize what changed since last snapshot | `snapshot-agents.sh status` |
| `help` | Show usage information | `snapshot-agents.sh help` |

**What gets tracked:**
- `home/` — Agent home directories (work output, logs, config, Maildir)
- `log/` — System logs (text files only)

**What is excluded:**
- All source code and config (managed by the main repo)
- `.gitkeep` files (belong to the main repo)
- `log/journal/` (binary systemd journal — not useful in git)

**Examples:**
```bash
# First-time setup
./scripts/snapshot-agents.sh init

# Snapshot as agents complete work
make snapshot MSG="alice finished onboarding"
make snapshot MSG="bob completed code review"

# Inspect what changed
make snapshot-status
make snapshot-diff

# Browse full history
make snapshot-log
./scripts/snapshot-agents.sh show HEAD~2 --stat
```

---

## load-preset.sh

Reads a declarative preset JSON file and translates it into a running swarm by calling `create-agent.sh`, `task.sh add`, and `send-mail.sh` in sequence. The compiler is a thin translation layer — all decision logic lives in the preset file itself.

**Usage:**
```bash
# Inside the container
load-preset.sh <file.json> [--dry-run] [--skip-existing] [--check-vars]

# From the host via Make
make load-preset FILE=presets/bug-triage.json [DRY_RUN=1] [SKIP_EXISTING=1]
```

**Arguments:**
- `<file.json>` (required) — Path to the preset JSON file.
- `--dry-run` (optional) — Print the commands that would run without executing them.
- `--skip-existing` (optional) — Skip `create-agent.sh` calls for users who already exist. Useful when re-loading a preset.
- `--check-vars` (optional) — List all environment variables referenced by the preset and exit. Shows which are set, which have defaults, and which are required but missing.

**Compilation phases:**
1. **Validate** — Parse JSON, verify required fields, check the DAG for cycles and invalid references
2. **Create agents** — Call `create-agent.sh` for each entry in the agents list
3. **Create tasks** — Call `task.sh add` for each task, wiring up `blocked_by` dependencies and owners
4. **Send mail** — Call `send-mail.sh` for each kickoff message entry
5. **Save state** — Record the loaded preset for reference

**Variable substitution:** Presets may use `${VAR}` and `${VAR:-default}` placeholders in task descriptions and mail bodies. At load time these are replaced by environment variables. Placeholders with `:-default` fall back to their default when the variable is unset; placeholders without a default are required and cause an error if unset.

Before expanding, the script reports which defaults are being applied:
```
  -> BUG_TITLE not set, using default: Bug Report
  -> BUG_DESCRIPTION not set, using default: See /home/shared/inputs/bug-report.md
```

To supply variables explicitly:
```bash
BUG_TITLE="Login timeout" BUG_DESCRIPTION="Users report 30s hangs" \
  load-preset.sh presets/bug-triage.json
```

To inspect variables without loading:
```bash
load-preset.sh presets/bug-triage.json --check-vars
```

**TUI interactive prompting:** The TUI detects preset variables and prompts for each one interactively. Variables can also be provided inline:
```
load-preset feature-build FEATURE_NAME="Dark mode"
```

**Preset JSON format:**
```json
{
  "name": "preset-name",
  "description": "What this preset does",
  "agents": [
    { "name": "alice", "persona": "coder", "instructions": "optional custom instructions" }
  ],
  "tasks": [
    {
      "id": "task-1",
      "title": "Task title",
      "description": "Detailed description with ${VARIABLES}",
      "owner": "alice",
      "blocked_by": []
    }
  ],
  "mail": [
    { "to": "alice", "subject": "Kickoff", "body": "Your task is ready" }
  ]
}
```

**Examples:**
```bash
# Preview without executing
make load-preset FILE=presets/feature-build.json DRY_RUN=1

# Load with explicit variables
FEATURE_NAME="Dark mode" REPO_PATH="/home/shared/webapp" \
  make load-preset FILE=presets/feature-build.json

# Re-load without recreating agents that already exist
make load-preset FILE=presets/bug-triage.json SKIP_EXISTING=1
```

---

## task.sh

Manages the shared DAG task board at `/home/shared/tasks.jsonl`. The board is append-only JSONL — the final entry for a given task ID represents its current state.

**Usage:**
```bash
task.sh <command> [args]
```

**Commands:**

| Command | Description | Example |
|---------|-------------|---------|
| `add` | Add a new task | `task.sh add "Build engine" --owner alice --blocked-by task-1` |
| `list` | List all tasks | `task.sh list [--owner alice] [--status pending]` |
| `ready` | List tasks with no unfinished blockers | `task.sh ready` |
| `update` | Update a task's status | `task.sh update task-abc completed` |
| `get` | Get details for a specific task | `task.sh get task-abc` |
| `graph` | Render the task dependency graph | `task.sh graph` |

---

## artifact.sh

Manages the shared artifact registry for inter-agent file sharing. Artifacts are files under `/home/shared/` that agents can produce and consume.

**Usage:**
```bash
artifact.sh <command> [args]
```

**Commands:**

| Command | Description | Example |
|---------|-------------|---------|
| `register` | Register a shared artifact | `artifact.sh register reports/output.csv` |
| `list` | List all registered artifacts | `artifact.sh list` |
| `get` | Get metadata for an artifact | `artifact.sh get reports/output.csv` |
| `read` | Read artifact contents | `artifact.sh read reports/output.csv` |

---

## agent-loop.mjs

A Node.js script that executes a single agentic work cycle via the Claude Agent SDK (`@anthropic-ai/claude-agent-sdk`). Called by `run-agent.sh` on each cycle iteration. **Not intended for manual use.**

**What it does:**
1. Sends a prompt to Claude instructing it to follow the agent's `CLAUDE.md` operating instructions
2. Claude checks for new mail, reads `TODO.md`, works on tasks, updates `MEMORY.md`, and reports results
3. The SDK handles all tool execution automatically (Bash, Read, Write, Edit, Glob, Grep)
4. Logs assistant output snippets and cycle results to stdout (captured by journald)
5. Exits with code 0 on success, 1 on failure

**Environment variables:**
| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | (required) | API key for Claude |
| `AGENT_USER` | `$USER` | Agent username (set by `run-agent.sh`) |
| `AGENT_MODEL` | `claude-opus-4-6` | Claude model to use |
| `AGENT_MAX_TURNS` | `50` | Maximum conversation turns per cycle |
| `AGENT_CYCLE_TIMEOUT_MS` | `300000` | Cycle timeout in milliseconds (5 min) |

**Security:** Runs with `permissionMode: "bypassPermissions"` since there is no human in the loop to approve tool calls. Agents are sandboxed by Unix permissions — no sudo access, and writes are restricted to the agent's own home directory.

---

## run-agent.sh

The entrypoint script executed by each agent's systemd service (`agent@<username>.service`). Runs as the agent user with their home directory as the working directory.

**Not intended for manual invocation** — systemd calls this automatically.

**What it does:**
1. Logs startup details (user, home directory, PID, config file presence)
2. Checks that `agents.md` and `.claude/config.json` exist in the agent's home
3. Loads API keys from global and per-agent configuration (see below)
4. Runs a continuous work cycle loop: invokes `agent-loop.mjs` on each iteration, then blocks on `inotifywait` watching `~/Maildir/new/` — waking immediately when new mail arrives, or after the configured interval elapses

**API Key Loading:**
1. Global defaults from `/etc/agent-api-keys/global.env` (if the file exists)
2. Per-agent overrides from `~/.claude/api-keys.env` (if the file exists)
3. Per-agent keys override global keys
4. All loaded keys are exported as environment variables

**Cycle loop configuration:**
| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_CYCLE_INTERVAL` | `300` | Maximum seconds between work cycles (new mail triggers an immediate cycle) |

**Logs:** Output goes to both the systemd journal and `/home/<username>/.agent.log`. View with:
```bash
make agent-logs NAME=alice
# or inside the container:
journalctl -u agent@alice.service -f
```

---

## agent-manager.sh

Boot-time reconciliation script that brings all registered agents' services back up after a container restart. Executed once at startup by the `agent-manager.service` systemd unit.

**Not intended for manual invocation.**

**What it does:**
1. Enumerates all users in the `agents` group
2. Verifies each user's account and home directory still exist
3. Creates `~/Maildir/{new,cur,tmp}` if missing (supports migration from older setups)
4. Enables and queues start for `agent@<username>.service` (non-blocking) and launches the mail watcher via `nohup su`
5. Regenerates mail aliases to match the current agent roster
6. Logs a summary of started vs. failed agents

---

## mail-watcher.sh

An inotify-based watcher that monitors each agent's `~/Maildir/new/` directory for incoming messages. When OpenSMTPD delivers a message, this script logs the event. The agent loop uses `inotifywait` independently to wake immediately on new mail.

Launched via `nohup su` by `create-agent.sh` and `agent-manager.sh`. **Not intended for manual invocation.** The PID is tracked at `/run/mail-watcher-<username>.pid`.

**What it does:**
1. Writes its own PID to `~/.mail-watcher.pid` for reliable cleanup at removal time
2. Ensures the `~/Maildir/{new,cur,tmp}` structure exists
3. Watches `~/Maildir/new/` with `inotifywait` for `CREATE` and `MOVED_TO` events
4. Logs each delivery event

**Logs:**
```bash
# View the mail watcher log
cat /var/log/mail-watcher-alice.log

# Follow it live
tail -f /var/log/mail-watcher-alice.log
```

---

## manage-api-keys.sh

Manages per-agent API keys stored in `~/.claude/api-keys.env` (root-owned, agent-readable).

**Usage:**
```bash
# Inside the container
manage-api-keys.sh <command> [args...]

# From the host via Make
make set-api-key NAME=alice KEY=ANTHROPIC_API_KEY=sk-xxx
make get-api-keys NAME=alice
make remove-api-key NAME=alice KEY=OPENAI_API_KEY
make clear-api-keys NAME=alice
make list-providers
```

**Commands:**

| Command | Description | Example |
|---------|-------------|---------|
| `set` | Set one or more API keys | `manage-api-keys.sh set alice ANTHROPIC_API_KEY=sk-xxx` |
| `get` | Show API keys (values masked) | `manage-api-keys.sh get alice` |
| `remove` | Remove specific API keys | `manage-api-keys.sh remove alice OPENAI_API_KEY` |
| `clear` | Remove all API keys | `manage-api-keys.sh clear alice` |
| `list-providers` | List known provider names | `manage-api-keys.sh list-providers` |

**Examples:**
```bash
# Set multiple keys at once
manage-api-keys.sh set bob OPENAI_API_KEY=sk-xxx MISTRAL_API_KEY=xxx

# Show keys for an agent (masked output)
manage-api-keys.sh get bob
# Output: OPENAI_API_KEY = sk-x...xxxx

# Remove a specific key
manage-api-keys.sh remove bob MISTRAL_API_KEY
```

**Security:**
- API key files are root-owned but readable by the agent user (mode 640)
- Values are masked on display (only the first and last 4 characters are shown)
- Files are kept in the root-owned `.claude/` directory

---

## sync-api-keys.sh

Synchronizes API key environment variables passed by the host into the container's global configuration file. Executed once at container startup by the `api-keys-sync.service` systemd unit.

**Not intended for manual invocation.**

**What it does:**
1. Reads API key environment variables passed through `docker-compose.yml`
2. Merges them with any static keys baked into the Docker image
3. Writes the combined set to `/etc/agent-api-keys/global.env`
4. Sets secure permissions on the output file (root-only, mode 600)

This mechanism lets you supply API keys from the host environment without embedding them in the image:
```bash
# On the host
export ANTHROPIC_API_KEY=sk-ant-xxx
docker-compose up -d
# The key is now available to all agents
```

---

## test-systemd-services.sh

Exercises the systemd service management infrastructure to verify it is fully functional inside the container. Tests cover cgroup v2, systemd health, service lifecycle, resource limits, journal logging, and the boot-time services.

**Usage:**
```bash
# Inside the container
test-systemd-services.sh [--verbose]

# From the host via Make
make test-systemd
make test-systemd VERBOSE=1
```

**Arguments:**
- `--verbose` / `-v` (optional) — Print extra diagnostic output per test.

**What it tests:**

| Phase | Tests |
|-------|-------|
| 1. cgroup v2 infrastructure | Filesystem type, writable hierarchy, child cgroup creation, memory/cpu controllers |
| 2. systemd health | PID 1 is systemd, basic.target/multi-user.target active, system state, journald |
| 3. Agent service template | `agent@.service` exists, `run-agent.sh` is executable |
| 4. Service lifecycle | daemon-reload, enable, start, list, stop, restart, disable |
| 5. Resource limits | MemoryMax=512M, CPUQuota=50%, NoNewPrivileges, RestrictSUIDSGID |
| 6. Journal logging | Journal entries recorded for the agent service |
| 7. Boot services | agent-manager.service, api-keys-sync.service |

**Exit codes:**
- `0` — All tests passed
- `1` — One or more tests failed

A temporary user (`__test_systemd__`) is created for the lifecycle tests and automatically removed when the script exits.

**Example output:**
```
systemd Service Management Test Harness
Platform: Linux 6.10.14-linuxkit x86_64
systemd:  systemd 256 (256.10-1-arch)

Phase 1: cgroup v2 infrastructure
  ✓ cgroup v2 filesystem detected (cgroup2fs)
  ✓ cgroup hierarchy is writable
  ✓ Can create child cgroups
  ✓ Memory controller available
  ✓ CPU controller available

Phase 2: systemd health
  ✓ systemd is PID 1
  ...

Summary
  Total: 24 tests
  Passed: 24

PASS — All tests passed. systemd service management is functional.
```

---

## Makefile Targets

The `Makefile` in the project root wraps the management scripts for host-side invocation (the container must be running for agent commands):

**Agent Management:**
```bash
make create-agent NAME=foo                        # Create agent with base persona
make create-agent NAME=foo PERSONA=coder          # Create agent with specialist persona
make create-agent NAME=foo INSTRUCTIONS="Focus on tests"     # Create with custom instructions
make create-agent NAME=foo API_KEY=ANTHROPIC_API_KEY=sk-xxx  # Create with API key
make update-agent NAME=foo PERSONA=coder          # Change an agent's persona
make remove-agent NAME=foo                        # Remove an agent
make list-agents                                  # List all agents and status
make list-personas                                # List available personas
make agent-logs NAME=foo                          # Tail systemd journal logs
make agent-shell NAME=foo                         # Open a shell as the agent user
make mail TO=alice MSG="Hello"                    # Send mail to agent (from root)
make mail TO=all MSG="Hi everyone"                # Send mail to all agents (group alias)
make mail TO=alice FROM=bob MSG="Hi"              # Send mail as a specific user
make mail TO=alice FROM=bob SUBJECT="Re: Task" MSG="Done"  # With subject
make sync-aliases                                 # Regenerate mail aliases
make soft-reset                                   # Remove all agents and clear logs
```

**API Key Management:**
```bash
make set-api-key NAME=foo KEY=ANTHROPIC_API_KEY=sk-xxx  # Set API key for agent
make get-api-keys NAME=foo                              # Show API keys (masked)
make remove-api-key NAME=foo KEY=OPENAI_API_KEY         # Remove specific key
make clear-api-keys NAME=foo                            # Remove all keys
make list-providers                                     # List known provider names
```

**Presets:**
```bash
make list-presets                                       # List available workflow presets
make load-preset FILE=presets/bug-triage.json           # Load a preset (creates agents + tasks + mail)
make load-preset FILE=presets/bug-triage.json DRY_RUN=1 # Preview without executing
make load-preset FILE=presets/feature-build.json SKIP_EXISTING=1  # Skip existing agents
```

**Testing:**
```bash
make test-systemd                      # Verify systemd service management works
make test-systemd VERBOSE=1            # Verbose output with diagnostics
```

**Snapshots (host-side — container not required):**
```bash
make snapshot-init                      # Initialize the snapshot repo
make snapshot                           # Snapshot current agent state
make snapshot MSG="after task 3"        # Snapshot with a custom message
make snapshot-log                       # Show snapshot history
make snapshot-diff                      # Show changes since last snapshot
make snapshot-status                    # Summarize changes since last snapshot
```
