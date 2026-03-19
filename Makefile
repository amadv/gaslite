.PHONY: help build up down restart shell logs clean reset soft-reset create-agent remove-agent update-agent list-agents list-personas agent-logs agent-shell mail sync-aliases set-api-key get-api-keys remove-api-key clear-api-keys list-providers snapshot-init snapshot snapshot-log snapshot-diff snapshot-status tui install-tui task-add task-list task-ready task-update task-graph swarm-status swarm-stop health artifact-list artifact-register artifact-get list-presets load-preset test-systemd

help:
	@echo "Container lifecycle:"
	@echo "  make build                  - Build the Docker image"
	@echo "  make up                     - Start the container (boots with systemd)"
	@echo "  make down                   - Stop and remove the container"
	@echo "  make restart                - Stop then start the container"
	@echo "  make shell                  - Open a root shell inside the container"
	@echo "  make logs                   - Stream container logs"
	@echo "  make clean                  - Remove the image (home directory preserved)"
	@echo "  make reset                  - Hard reset: stop container, remove image, erase all data"
	@echo "  make soft-reset             - Remove all agents and clear logs without stopping the container"
	@echo ""
	@echo "Agent management (requires a running container):"
	@echo "  make create-agent NAME=alice                           - Create an agent with the base persona"
	@echo "  make create-agent NAME=alice PERSONA=coder             - Create an agent with a specialist persona"
	@echo "  make create-agent NAME=alice INSTRUCTIONS=\"Write tests\" - Create an agent with custom instructions"
	@echo "  make create-agent NAME=alice API_KEY=ANTHROPIC_API_KEY=sk-xxx - Create an agent with an API key"
	@echo "  make update-agent NAME=alice PERSONA=coder             - Switch an agent's persona"
	@echo "  make remove-agent NAME=alice                           - Delete an agent user"
	@echo "  make list-agents                                       - Show all agents and their status"
	@echo "  make list-personas                                     - Show available personas"
	@echo "  make agent-logs NAME=alice                             - Follow logs for an agent"
	@echo "  make agent-shell NAME=alice                            - Open a shell as an agent user"
	@echo "  make mail TO=alice MSG=\"Hello\"                         - Send mail to an agent (sent as root)"
	@echo "  make mail TO=all MSG=\"Announcement\"                    - Send mail to all agents via group alias"
	@echo "  make mail TO=alice FROM=bob MSG=\"Hi\"                   - Send mail as a specific user"
	@echo "  make sync-aliases                                      - Rebuild mail aliases from the agents group"
	@echo ""
	@echo "Snapshots (runs on the host — container not required):"
	@echo "  make snapshot-init                      - Initialise the snapshot repository"
	@echo "  make snapshot                           - Snapshot current agent state"
	@echo "  make snapshot MSG=\"checkpoint\"          - Snapshot with a custom message"
	@echo "  make snapshot-log                       - View snapshot history"
	@echo "  make snapshot-diff                      - Show changes since last snapshot"
	@echo "  make snapshot-status                    - Summarise uncommitted changes"
	@echo ""
	@echo "Swarm orchestration (requires a running container):"
	@echo "  make swarm-status                       - Display task board, agent health, cost, and events"
	@echo "  make swarm-stop                         - Halt all agents and the orchestrator"
	@echo "  make swarm-stop REASON=\"done\"           - Halt with an explanation"
	@echo "  make health                             - Check agent heartbeat health"
	@echo "  make task-add SUBJECT=\"Build API\" OWNER=alice          - Add a task to the board"
	@echo "  make task-add SUBJECT=\"Deploy\" OWNER=bob BLOCKED_BY=task-abc123 - Add with a dependency"
	@echo "  make task-list                          - Show all tasks"
	@echo "  make task-ready                         - Show tasks whose blockers are satisfied"
	@echo "  make task-update ID=task-abc123 STATUS=completed RESULT=\"Done\" - Update a task"
	@echo "  make task-graph                         - Render the task dependency graph"
	@echo "  make artifact-list                      - List all shared artifacts"
	@echo "  make artifact-register FILE=reports/out.csv DESCRIPTION=\"Q4\" - Register an artifact"
	@echo "  make artifact-get FILE=reports/out.csv  - Get metadata for an artifact"
	@echo ""
	@echo "Workflow presets:"
	@echo "  make list-presets                       - List available presets"
	@echo "  make load-preset FILE=presets/foo.json  - Execute a workflow preset"
	@echo "  make load-preset FILE=... DRY_RUN=1    - Preview a preset without running it"
	@echo "  FEATURE_NAME=\"Widget\" make load-preset FILE=presets/feature-build.json"
	@echo ""
	@echo "Testing:"
	@echo "  make test-systemd                       - Confirm systemd service management works"
	@echo "  make test-systemd VERBOSE=1             - Same with extra diagnostic output"
	@echo ""
	@echo "Interactive TUI:"
	@echo "  make install-tui                        - Install TUI dependencies (first time only)"
	@echo "  make tui                                - Launch the interactive TUI"
	@echo ""
	@echo "API key management (requires a running container):"
	@echo "  make set-api-key NAME=alice KEY=ANTHROPIC_API_KEY=sk-xxx - Assign a key to an agent"
	@echo "  make get-api-keys NAME=alice            - Display an agent's keys (masked)"
	@echo "  make remove-api-key NAME=alice KEY=OPENAI_API_KEY        - Remove a specific key"
	@echo "  make clear-api-keys NAME=alice          - Remove all keys from an agent"
	@echo "  make list-providers                     - List recognised provider variable names"

# --- Container lifecycle ---

build:
	docker compose build

up:
	docker compose up -d

down:
	docker compose down

restart: down up

shell:
	docker compose exec gaslite /bin/bash

logs:
	docker compose logs -f --timestamps

clean: down
	docker rmi gaslite:latest || true
	@echo "Note: agent home directories preserved in ./home/"

soft-reset:
	docker compose exec -T gaslite /usr/local/bin/soft-reset.sh --yes

reset: down
	docker rmi gaslite:latest || true
	sudo find ./home -mindepth 1 ! -name '.gitkeep' -delete
	sudo find ./log -mindepth 1 ! -name '.gitkeep' -delete
	@echo "Reset complete. All agent data (including Maildir) and logs have been removed."

# --- Agent management ---

create-agent:
ifndef NAME
	$(error NAME is required. Usage: make create-agent NAME=alice [PERSONA=coder] [INSTRUCTIONS="text"] [API_KEY=PROVIDER=key])
endif
	docker compose exec -T gaslite /usr/local/bin/create-agent.sh $(NAME) \
		$(if $(PERSONA),--persona $(PERSONA)) \
		$(if $(INSTRUCTIONS),--instructions "$(INSTRUCTIONS)") \
		$(if $(API_KEY),--api-key $(API_KEY))

remove-agent:
ifndef NAME
	$(error NAME is required. Usage: make remove-agent NAME=alice)
endif
	docker compose exec -T gaslite /usr/local/bin/remove-agent.sh $(NAME)

update-agent:
ifndef NAME
	$(error NAME is required. Usage: make update-agent NAME=alice PERSONA=coder)
endif
ifndef PERSONA
	$(error PERSONA is required. Usage: make update-agent NAME=alice PERSONA=coder)
endif
	docker compose exec -T gaslite /usr/local/bin/update-agent.sh $(NAME) --persona $(PERSONA)

list-agents:
	docker compose exec -T gaslite /usr/local/bin/list-agents.sh

list-personas:
	@echo "Available personas (from config/personas/):"
	@echo ""
	@echo "  base       - Default persona applied to every agent"
	@for f in config/personas/*.md; do \
		name=$$(basename "$$f" .md); \
		if [ "$$name" != "base" ]; then \
			echo "  $$name"; \
		fi; \
	done
	@echo ""
	@echo "Usage: make create-agent NAME=alice PERSONA=<name>"

agent-logs:
ifndef NAME
	$(error NAME is required. Usage: make agent-logs NAME=alice)
endif
	docker compose exec -T gaslite journalctl -u agent@$(NAME).service -f

agent-shell:
ifndef NAME
	$(error NAME is required. Usage: make agent-shell NAME=alice)
endif
	docker compose exec --user $(NAME) gaslite /bin/bash

sync-aliases:
	docker compose exec -T gaslite /usr/local/bin/sync-aliases.sh

mail:
ifndef TO
	$(error TO is required. Usage: make mail TO=alice MSG="Hello" [FROM=bob] [SUBJECT="Hi"])
endif
ifndef MSG
	$(error MSG is required. Usage: make mail TO=alice MSG="Hello" [FROM=bob] [SUBJECT="Hi"])
endif
	docker compose exec -T gaslite /usr/local/bin/send-mail.sh "$(TO)" $(if $(FROM),--from "$(FROM)") $(if $(SUBJECT),--subject "$(SUBJECT)") -- "$(MSG)"

# --- API key management ---

set-api-key:
ifndef NAME
	$(error NAME is required. Usage: make set-api-key NAME=alice KEY=PROVIDER=value)
endif
ifndef KEY
	$(error KEY is required. Usage: make set-api-key NAME=alice KEY=ANTHROPIC_API_KEY=sk-xxx)
endif
	docker compose exec -T gaslite /usr/local/bin/manage-api-keys.sh set $(NAME) $(KEY)

get-api-keys:
ifndef NAME
	$(error NAME is required. Usage: make get-api-keys NAME=alice)
endif
	docker compose exec -T gaslite /usr/local/bin/manage-api-keys.sh get $(NAME)

remove-api-key:
ifndef NAME
	$(error NAME is required. Usage: make remove-api-key NAME=alice KEY=PROVIDER)
endif
ifndef KEY
	$(error KEY is required. Usage: make remove-api-key NAME=alice KEY=OPENAI_API_KEY)
endif
	docker compose exec -T gaslite /usr/local/bin/manage-api-keys.sh remove $(NAME) $(KEY)

clear-api-keys:
ifndef NAME
	$(error NAME is required. Usage: make clear-api-keys NAME=alice)
endif
	docker compose exec -T gaslite /usr/local/bin/manage-api-keys.sh clear $(NAME)

list-providers:
	docker compose exec -T gaslite /usr/local/bin/manage-api-keys.sh list-providers

# --- Agent snapshots (host-side) ---

snapshot-init:
	@./scripts/snapshot-agents.sh init

snapshot:
	@./scripts/snapshot-agents.sh create "$(if $(MSG),$(MSG),)"

snapshot-log:
	@./scripts/snapshot-agents.sh log

snapshot-diff:
	@./scripts/snapshot-agents.sh diff

snapshot-status:
	@./scripts/snapshot-agents.sh status

# --- Swarm orchestration ---

swarm-status:
	docker compose exec -T gaslite /usr/local/bin/swarm-status.sh

swarm-stop:
	docker compose exec -T gaslite /usr/local/bin/stop-swarm.sh $(if $(REASON),--reason "$(REASON)")

health:
	docker compose exec -T gaslite /usr/local/bin/check-health.sh

task-add:
ifndef SUBJECT
	$(error SUBJECT is required. Usage: make task-add SUBJECT="Build API" OWNER=alice [DESCRIPTION="text"] [BLOCKED_BY=task-id])
endif
ifndef OWNER
	$(error OWNER is required. Usage: make task-add SUBJECT="Build API" OWNER=alice)
endif
	docker compose exec -T gaslite /usr/local/bin/task.sh add "$(SUBJECT)" --owner $(OWNER) \
		$(if $(DESCRIPTION),--description "$(DESCRIPTION)") \
		$(if $(BLOCKED_BY),--blocked-by $(BLOCKED_BY))

task-list:
	docker compose exec -T gaslite /usr/local/bin/task.sh list $(if $(OWNER),--owner $(OWNER)) $(if $(STATUS),--status $(STATUS))

task-ready:
	docker compose exec -T gaslite /usr/local/bin/task.sh ready $(if $(OWNER),--owner $(OWNER))

task-update:
ifndef ID
	$(error ID is required. Usage: make task-update ID=task-abc123 STATUS=completed [RESULT="summary"])
endif
ifndef STATUS
	$(error STATUS is required. Usage: make task-update ID=task-abc123 STATUS=completed [RESULT="summary"])
endif
	docker compose exec -T gaslite /usr/local/bin/task.sh update $(ID) --status $(STATUS) \
		$(if $(RESULT),--result "$(RESULT)")

task-graph:
	docker compose exec -T gaslite /usr/local/bin/task.sh graph

artifact-list:
	docker compose exec -T gaslite /usr/local/bin/artifact.sh list $(if $(PRODUCER),--producer $(PRODUCER))

artifact-register:
ifndef FILE
	$(error FILE is required. Usage: make artifact-register FILE=reports/out.csv [DESCRIPTION="text"])
endif
	docker compose exec -T gaslite /usr/local/bin/artifact.sh register $(FILE) \
		$(if $(DESCRIPTION),--description "$(DESCRIPTION)")

artifact-get:
ifndef FILE
	$(error FILE is required. Usage: make artifact-get FILE=reports/out.csv)
endif
	docker compose exec -T gaslite /usr/local/bin/artifact.sh get $(FILE)

# --- Workflow presets ---

list-presets:
	@echo "Available presets (in presets/):"
	@echo ""
	@for f in presets/*.json; do \
		name=$$(basename "$$f" .json); \
		desc=$$(jq -r '.description // "No description"' "$$f"); \
		printf "  %-25s %s\n" "$$name" "$$desc"; \
	done
	@echo ""
	@echo "Usage: make load-preset FILE=presets/<name>.json [DRY_RUN=1] [SKIP_EXISTING=1]"
	@echo "       Pass variables via env: FEATURE_NAME=\"x\" make load-preset FILE=..."

load-preset:
ifndef FILE
	$(error FILE is required. Usage: make load-preset FILE=presets/foo.json [DRY_RUN=1] [SKIP_EXISTING=1])
endif
	./scripts/load-preset.sh $(FILE) \
		$(if $(filter 1,$(DRY_RUN)),--dry-run) \
		$(if $(filter 1,$(SKIP_EXISTING)),--skip-existing)

# --- Testing ---

test-systemd:
	docker compose exec -T gaslite /usr/local/bin/test-systemd-services.sh $(if $(filter 1,$(VERBOSE)),--verbose)

# --- Interactive TUI ---

install-tui:
	@cd tui && npm install

tui:
	@node cli.mjs
