# AI Stack — top-level Makefile
# Run `make` or `make help` to see available targets.

COMPOSE_FILES := \
	compose/ollama.yaml \
	compose/whisper.yaml \
	compose/piper.yaml \
	compose/frigate.yaml \
	compose/openwebui.yaml \
	compose/nginx.yaml \
	compose/monitoring.yaml \
	compose/orchestrator.yaml

COMPOSE_ARGS := $(foreach f,$(COMPOSE_FILES),-f $(f))

.DEFAULT_GOAL := help

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@awk 'BEGIN { \
		FS = ":.*##"; \
		printf "\n\033[1mAI Stack\033[0m\n\n"; \
		printf "  \033[36mmake <target>\033[0m\n\n"; \
		printf "\033[1mTargets:\033[0m\n" \
	} \
	/^[a-zA-Z_-]+:.*?##/ { \
		printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 \
	} \
	/^## / { \
		printf "\n\033[1m%s\033[0m\n", substr($$0, 4) \
	}' $(MAKEFILE_LIST)
	@echo

# ── Setup ─────────────────────────────────────────────────────────────────────

## Setup

.PHONY: setup
setup: ## Full first-time setup (drives, mounts, secrets, host config, images, service start)
	bash setup.sh

.PHONY: build
build: ## Build all custom local Docker images under build/
	bash build-images.sh

.PHONY: images
images: build

# ── Service ───────────────────────────────────────────────────────────────────

## Service

.PHONY: start
start: ## Start ai-stack.service
	sudo systemctl start ai-stack.service

.PHONY: up
up: start

.PHONY: stop
stop: ## Stop ai-stack.service
	sudo systemctl stop ai-stack.service

.PHONY: down
down: stop

.PHONY: restart
restart: ## Restart ai-stack.service
	sudo systemctl restart ai-stack.service

.PHONY: status
status: ## Show ai-stack.service status
	sudo systemctl status ai-stack.service --no-pager

# ── Operations ────────────────────────────────────────────────────────────────

## Operations

.PHONY: logs
logs: ## Follow logs for all containers (Ctrl-C to exit)
	sudo docker compose $(COMPOSE_ARGS) logs -f

.PHONY: pull
pull: ## Pull latest upstream images (does not affect local: images)
	sudo docker compose $(COMPOSE_ARGS) pull --ignore-buildable
