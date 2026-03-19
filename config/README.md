# Configuration Files

Files in this directory are copied into the Docker image at build time.

## Directory Structure

### `api-keys/` — API Key Configuration

Contents are copied to `/etc/agent-api-keys/` in the container. Provides global LLM API key configuration that applies to all agents.

**Files:**
- `global.env.template` — Lists all supported API key variable names with comments
- `.gitignore` — Prevents actual key files from being committed

**Configuring global API keys:**

Option 1 — pass from the host environment (recommended):
```bash
export ANTHROPIC_API_KEY=sk-ant-xxx
export OPENAI_API_KEY=sk-xxx
docker-compose up -d
```
`sync-api-keys.sh` automatically writes these to `/etc/agent-api-keys/global.env` at container startup.

Option 2 — bake into the image (only for private images):
1. Copy `global.env.template` to `global.env`
2. Uncomment and fill in the keys you need
3. Rebuild: `docker-compose build`

**Supported providers:**
- Anthropic (`ANTHROPIC_API_KEY`)
- OpenAI (`OPENAI_API_KEY`)
- Google/Gemini (`GOOGLE_API_KEY`, `GEMINI_API_KEY`)
- Mistral (`MISTRAL_API_KEY`)
- Cohere (`COHERE_API_KEY`)
- Groq (`GROQ_API_KEY`)
- Together.ai (`TOGETHER_API_KEY`)
- Fireworks.ai (`FIREWORKS_API_KEY`)
- Perplexity (`PERPLEXITY_API_KEY`)
- Replicate (`REPLICATE_API_TOKEN`)
- Hugging Face (`HUGGINGFACE_API_KEY`, `HF_TOKEN`)
- AWS Bedrock (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`)
- Azure OpenAI (`AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`)
- GitHub (`GITHUB_TOKEN`, `GH_TOKEN`)

**Per-agent API keys:**
Use `manage-api-keys.sh` or pass `--api-key` to `create-agent.sh`. Per-agent keys override global keys for that agent. See [`scripts/README.md`](../scripts/README.md) for details.

---

### `personas/` — Agent Persona Definitions

Contents are copied to `/etc/agent-personas/` in the container. These files are used by `create-agent.sh` to compose each agent's `agents.md`.

**Available personas:**
- `base.md` — Base persona applied to every agent (autonomy, collaboration, constraints)
- `analyst.md` — Data analysis and reporting
- `architect.md` — System design and technical RFCs
- `coder.md` — Software development
- `devops.md` — Build scripts, CI/CD, and infrastructure automation
- `editor.md` — Content review for clarity, consistency, and tone
- `manager.md` — Team coordination and task delegation
- `ops.md` — Request triage and routing to specialists
- `planner.md` — Goal-to-spec breakdown with acceptance criteria
- `product-manager.md` — Product vision, feature prioritization, and user requirements
- `qa.md` — Testing, edge cases, and bug reporting
- `researcher.md` — Research and information gathering
- `reviewer.md` — Code review
- `security.md` — Security audits and vulnerability review
- `writer.md` — Technical documentation and content

The base persona is always included. Specialist personas are layered on top when specified with `--persona`.

**Adding a new persona:**
1. Create a `.md` file in this directory
2. Use the three-section structure: `## Identity` (with `- **Role**: ...` and `- **Purpose**: ...`), `## Instructions`, `## Output Format`
3. Rebuild: `docker-compose build`
4. Use the new persona: `make create-agent NAME=alice PERSONA=<name>`

---

### `skills/` — Agent Skill Packs

Contents are copied to `/etc/agent-skills/` in the container. `create-agent.sh` uses these to populate each agent's `~/.claude/skills/` directory at creation time.

**Directory structure:**
```
skills/
├── _universal/                    # Installed to every agent
│   ├── task-workflow/SKILL.md     # Check ready tasks, claim, work, complete
│   ├── artifact-sharing/SKILL.md  # Produce/consume shared files
│   ├── report-results/SKILL.md    # Write good result summaries
│   └── agent-communication/SKILL.md # Discover team, send mail, check inbox
├── coder/                         # Installed when persona = coder
│   ├── project-setup/SKILL.md
│   ├── test-and-validate/SKILL.md
│   ├── focused-pr/SKILL.md
│   └── code-refactor/SKILL.md
├── researcher/                    # Installed when persona = researcher
│   ├── structured-research/SKILL.md
│   └── source-evaluation/SKILL.md
├── architect/
├── security/
├── qa/
├── writer/
├── editor/
├── reviewer/
├── planner/
├── analyst/
├── devops/
├── manager/
└── ops/
```

**Persona-to-directory mapping:** The directory name under `skills/` must exactly match the persona filename without `.md`. For example, the `coder.md` persona maps to `skills/coder/`. The `_universal/` directory is a special case — always installed regardless of persona.

**Skill file format:** Each skill is a directory containing a `SKILL.md` file in Claude Code format:
```markdown
---
name: skill-name
description: What the skill does
---

# Skill Name

Procedural instructions with real, runnable commands...
```

**Installation behavior:**
- Skills are **copied** into the agent's home directory, not symlinked, so agents can modify them at runtime
- **Existing skill directories are never overwritten** — agent-modified skills survive re-runs
- After installation, the skills directory is `chown`'d to the agent for writability

**Adding a persona-specific skill:**
1. Create a directory: `config/skills/<persona>/<skill-name>/`
2. Write a `SKILL.md` file with YAML frontmatter and procedural content
3. Rebuild: `docker-compose build`
4. New agents with that persona will automatically receive the skill

**Adding a universal skill:**
1. Create a directory: `config/skills/_universal/<skill-name>/`
2. Write a `SKILL.md` file
3. Rebuild — every new agent receives it regardless of persona

---

### `smtpd/` — OpenSMTPD Configuration

Contents are copied to `/etc/smtpd/` in the container. Used for mail alias configuration.

OpenSMTPD is configured for **Maildir delivery** — each message lands as a separate file in `~/Maildir/new/`. A per-agent `mail-watcher.sh` process (inotify-based) watches for new deliveries and logs them. Messages remain in `new/` until the agent reads them via s-nail (which moves them to `cur/`, following Maildir convention). The agent loop uses `inotifywait` to wake immediately on new mail instead of polling.

**Files:**
- `aliases.static` — Custom per-agent mail aliases merged into the generated aliases file

**How mail aliases work:**

The `all` group alias is auto-generated by `sync-aliases.sh` whenever agents are added or removed, and delivers to every registered agent.

Custom aliases are defined in `aliases.static` using the format `alias: recipient1, recipient2` and are merged into the final `/etc/smtpd/aliases` file.

**Examples:**
```
# In aliases.static:
devs: alice, bob         # Mail to 'devs' delivers to alice and bob
lead: alice              # Mail to 'lead' delivers to alice only
```

After editing `aliases.static`, rebuild the image and run `make sync-aliases` to apply the changes.

---

### `systemd/` — Systemd Service Definitions

Unit files for agent lifecycle management. Copied to `/etc/systemd/system/` in the container.

**Files:**
- `agent@.service` — Per-agent service template. Runs `run-agent.sh` as the agent user. Sets `MAIL=/home/%i/Maildir` for Maildir-based mail reading. **Note:** In Docker, agents are launched via `nohup su` instead of this service due to cgroup v2 constraints (see `create-agent.sh`).
- `mail-watcher@.service` — Per-agent Maildir watcher template for non-Docker deployments. In Docker, the watcher is launched via `nohup su` by `create-agent.sh` and `agent-manager.sh`. The watcher writes its PID to `~/.mail-watcher.pid` for reliable cleanup.
- `agent-manager.service` — Boot-time reconciliation service. Ensures all registered agents have running services and mail watchers after a container restart.
- `api-keys-sync.service` — Boot-time API key sync. Merges host environment variables into `/etc/agent-api-keys/global.env`.

---

### `skel/` — New User Home Directory Template

Contents are copied to `/etc/skel/` in the container. Every new agent's home directory is seeded from these files by `useradd`.

**Files:**
- `.bashrc` — Default bash configuration for interactive shells
- `.bash_profile` — Bash login configuration
- `.gitconfig` — Default git configuration (defaultBranch, editor, pull strategy)
- `CLAUDE.md` — Default operating instructions for Claude Code agents
- `agents.md` — Agent persona configuration (generated by `create-agent.sh`, not from skel)
- `TODO.md` — Starter task list for tracking work
- `MEMORY.md` — Starter persistent memory file for learnings and context

**Note:** Agent skills are installed to `~/.claude/skills/` by `create-agent.sh`, not via skel. Skills use the Claude Code format — see the `skills/` section above.

**How to customize:**
1. Edit or add files here
2. Rebuild: `docker-compose build`
3. New agents automatically receive the updated files

**Adding systemd user services:**
- Place service files in `skel/.config/systemd/user/`
- Enable them via `.bash_profile` or `.bashrc`:
  ```bash
  systemctl --user enable myservice.service
  systemctl --user start myservice.service
  ```

---

### `profile.d/` — Global Login Environment Scripts

Contents are copied to `/etc/profile.d/` in the container. Scripts here run for every user at login.

**Files:**
- `agent-env.sh` — Global agent environment setup (platform vars, umask, PATH, MAIL)
- `nvm.sh` — Loads nvm (Node Version Manager) for all users

**How to add a new global script:**
1. Create a `.sh` file in this directory
2. The Dockerfile sets executable permissions automatically
3. Rebuild: `docker-compose build`
4. The script runs for all users on login

**Best practices:**
- Use descriptive filenames (e.g., `company-env.sh`, `dev-tools.sh`)
- Scripts must be idempotent — they run on every login
- Keep scripts fast to avoid login delays
- Export environment variables that downstream processes need
- Use this directory for global PATH modifications

---

## Examples

### Add a custom command available to all agents

Create `config/profile.d/custom-commands.sh`:
```bash
#!/bin/bash
greet() {
    echo "Hello $(whoami), ready to work."
}
export -f greet
```

### Pre-configure a custom bash alias for new agents

Edit `config/skel/.bashrc`:
```bash
# Shortcut aliases
alias ll='ls -alF'
alias gs='git status'
```

### Add a custom mail alias for a team

Edit `config/smtpd/aliases.static`:
```
backend: alice, bob
```

Then rebuild and run `make sync-aliases`.
