# Travel Route Planner - Development Makefile
.PHONY: help build run test clean docker-build docker-run docker-dev docker-deploy docker-stop docker-stop-deploy docker-prune docker-logs api-build api-run api-test api-test-go api-repair-sections flutter-gen-l10n seed-local wt-new wt-init wt-rm wt-list wt-prune test-db

# Variables
API_DIR = src/packages/api
FLUTTER_DIR = src/packages/flutter-app

# Per-worktree parallel-lane config: `make wt-new` (scripts/worktree.sh) writes
# .wt.env at the worktree root with GTT_SLOT / GTT_PROJECT / GTT_GATEWAY_PORT /
# GTT_PG_PORT / TEST_DATABASE_URL so each worktree runs its own dev stack on
# its own ports. Absent — the main checkout — the defaults below reproduce the
# single-stack behavior exactly. Exported so compose interpolation, scripts,
# and `go test` all see them.
-include .wt.env
GTT_PROJECT ?= development
GTT_GATEWAY_PORT ?= 3000
GTT_PG_PORT ?= 5432
export GTT_PROJECT GTT_GATEWAY_PORT GTT_PG_PORT TEST_DATABASE_URL

DOCKER_DEV_COMPOSE = docker compose -f dockerize/development/docker-compose.yml
DOCKER_DEPLOY_COMPOSE = docker compose -f dockerize/deployment/docker-compose.yml
GATEWAY_URL = http://localhost:$(GTT_GATEWAY_PORT)

# Default target
help: ## Show this help message
	@echo "Travel Route Planner - Available Commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Docker commands
docker-build: docker-build-deploy ## Build deployment Docker images (alias)

docker-build-deploy: ## Build deployment stack images
	$(DOCKER_DEPLOY_COMPOSE) build

docker-build-dev: ## Build development stack images
	$(DOCKER_DEV_COMPOSE) build

docker-dev: ## Run development stack (Flutter hot reload + API + gateway on :3000)
	$(DOCKER_DEV_COMPOSE) up --build

docker-dev-bg: ## Run development stack in background
	$(DOCKER_DEV_COMPOSE) up -d --build

docker-deploy: ## Run deployment stack (static Flutter + API + gateway on :3000)
	$(DOCKER_DEPLOY_COMPOSE) up --build

docker-deploy-bg: ## Run deployment stack in background
	$(DOCKER_DEPLOY_COMPOSE) up -d --build

docker-run: docker-deploy ## Run deployment stack (alias for docker-deploy)

docker-run-bg: docker-deploy-bg ## Run deployment stack in background

docker-stop: ## Stop this checkout's dev stack (deploy stack: docker-stop-deploy)
	-$(DOCKER_DEV_COMPOSE) down

docker-stop-deploy: ## Stop the deployment stack
	-$(DOCKER_DEPLOY_COMPOSE) down

docker-logs: ## Show deployment stack logs
	$(DOCKER_DEPLOY_COMPOSE) logs -f

docker-logs-dev: ## Show development stack logs
	$(DOCKER_DEV_COMPOSE) logs -f

docker-logs-api: ## Show API logs (deployment stack)
	$(DOCKER_DEPLOY_COMPOSE) logs -f api

# API commands
api-deps: ## Download API dependencies
	cd $(API_DIR) && go mod tidy

api-build: ## Build the API binary
	cd $(API_DIR) && go build -o travel-route-planner .

api-run: ## Run the API locally on :8080
	cd $(API_DIR) && go run .

api-test: ## Run API tests against this checkout's gateway (BASE_URL overrides)
	cd $(API_DIR) && BASE_URL="$(if $(BASE_URL),$(BASE_URL),$(GATEWAY_URL))" ./test_examples.sh

api-test-go: ## Run Go tests (integration suite uses TEST_DATABASE_URL from .wt.env if present)
	cd $(API_DIR) && go test ./...

api-fmt: ## Format Go code
	cd $(API_DIR) && go fmt ./...

api-vet: ## Run go vet
	cd $(API_DIR) && go vet ./...

api-migrate: ## Apply database migrations (needs DATABASE_URL; runs on boot too)
	cd $(API_DIR) && go run . migrate

api-repair-sections: ## Report trips whose cities the old section splice duplicated (APPLY=1 to fix, TRIP=<uuid> for one, VERBOSE=1 for detail)
	cd $(API_DIR) && go run . repair-sections $(if $(APPLY),-apply) $(if $(TRIP),-trip $(TRIP)) $(if $(VERBOSE),-v)

api-sqlc: ## Generate type-safe DB code from SQL (install: go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest)
	cd $(API_DIR) && PATH="$$PATH:$$(go env GOPATH)/bin" sqlc generate

# Flutter commands
flutter-deps: ## Install Flutter dependencies
	cd $(FLUTTER_DIR) && flutter pub get

flutter-build-web: ## Build Flutter web app
	cd $(FLUTTER_DIR) && flutter build web --dart-define=API_BASE_URL=/api/v1

flutter-build-models: ## Generate Flutter model code
	cd $(FLUTTER_DIR) && dart run build_runner build

flutter-gen-l10n: ## Regenerate localizations from the ARB files
	cd $(FLUTTER_DIR) && flutter gen-l10n

flutter-run: ## Run Flutter app locally (use --dart-define for API URL if not using docker-dev)
	cd $(FLUTTER_DIR) && flutter run --dart-define=API_BASE_URL=http://localhost:8080/api/v1

flutter-test: ## Run Flutter tests
	cd $(FLUTTER_DIR) && flutter test

flutter-analyze: ## Analyze Flutter code
	cd $(FLUTTER_DIR) && flutter analyze

# Development commands
dev: docker-dev ## Start development Docker stack (alias)

dev-api: api-run ## Start API development server locally

test: api-test ## Run all tests

clean: ## Clean build artifacts + stop this checkout's dev stack
	cd $(API_DIR) && rm -f travel-route-planner
	$(MAKE) docker-stop

docker-prune: ## MACHINE-WIDE docker prune — affects every project and worktree
	docker system prune -f

# Setup commands
setup: ## Initial project setup
	@echo "Setting up Travel Route Planner development environment..."
	cd $(API_DIR) && go mod tidy
	cd $(FLUTTER_DIR) && flutter pub get
	@echo "Setup complete!"
	@echo ""
	@echo "Quick Start:"
	@echo "  make docker-dev      # Hot reload at $(GATEWAY_URL)"
	@echo "  make docker-deploy   # Static build at $(GATEWAY_URL)/app/"
	@echo "  make api-run         # API only on http://localhost:8080"

# Parallel worktrees ("lanes") — one branch + port slot + dev stack each.
# scripts/worktree.sh assigns slot N => gateway 3000+N, postgres 5432+N.
wt-new: ## Create a parallel worktree + port slot (NAME=<branch> [SLOT=n])
	./scripts/worktree.sh new "$(NAME)" $(if $(SLOT),--slot $(SLOT))

wt-init: ## Provision the CURRENT worktree with a port slot ([SLOT=n])
	./scripts/worktree.sh init $(if $(SLOT),--slot $(SLOT))

wt-rm: ## Tear down a worktree: stack down -v, worktree + local/remote branch removed (NAME=... [FORCE=1] [KEEP_REMOTE=1])
	./scripts/worktree.sh rm "$(NAME)" $(if $(FORCE),--force) $(if $(KEEP_REMOTE),--keep-remote)

wt-list: ## List worktrees, slots, ports, and running stacks
	./scripts/worktree.sh list

wt-prune: ## Remove orphaned .claude/worktrees dirs (list only; YES=1 deletes)
	./scripts/worktree.sh prune $(if $(YES),--yes)

test-db: ## Create travel_planner_test on this checkout's postgres (idempotent)
	@docker exec $(GTT_PROJECT)-postgres-1 psql -U travel -d travel_planner -tAc \
		"SELECT 1 FROM pg_database WHERE datname='travel_planner_test'" | grep -q 1 || \
		docker exec $(GTT_PROJECT)-postgres-1 createdb -U travel travel_planner_test

# Health check
health: ## Check API health via gateway
	curl -s $(GATEWAY_URL)/api/v1/health | jq '.' || echo "Gateway/API not running or jq not installed"

health-gateway: ## Check gateway health
	curl -s $(GATEWAY_URL)/health || echo "Gateway not running"

health-all: ## Check gateway and API health
	@echo "Checking gateway..."
	@curl -s $(GATEWAY_URL)/health || echo "Gateway not running"
	@echo ""
	@echo "Checking API via gateway..."
	@curl -s $(GATEWAY_URL)/api/v1/health | jq '.' || echo "API not reachable via gateway"

# Quick test commands
test-route: ## Test route optimization via gateway
	curl -s -X POST $(GATEWAY_URL)/api/v1/optimize-route \
		-H "Content-Type: application/json" \
		-d @$(API_DIR)/test_data.json | jq '.'

test-places: ## Test place search via gateway
	curl -s "$(GATEWAY_URL)/api/v1/places/search?q=paris" | jq '.'

test-countries: ## Test country optimization via gateway
	curl -s -X POST $(GATEWAY_URL)/api/v1/optimize-countries \
		-H "Content-Type: application/json" \
		-d '{"countries":[{"code":"US","name":"United States","latitude":39.8283,"longitude":-98.5795,"min_stay_days":7}],"optimize_for":"balanced"}' | jq '.'

# Content seeding (see specs/local-content-seeding and content/local/README.md)
# Credentials come from the environment: SEED_TOKEN, or SEED_EMAIL+SEED_PASSWORD.
seed-local: ## Bulk-ingest local content via admin API (CONTENT_DIR=./content/local, CITY=<slug>, BASE_URL=gateway)
	@BASE_URL="$(if $(BASE_URL),$(BASE_URL),$(GATEWAY_URL))" \
		CONTENT_DIR="$(CONTENT_DIR)" CITY="$(CITY)" \
		./scripts/seed_local_content.sh

# End-to-end smoke test — registers a throwaway user, walks the traveler journey
# (auth, trip, item, share/OG, export, notifications), then tears down.
# Rehearse against the dev stack; run against prod the moment DNS flips. Env vars
# pass through: SMOKE_SEED_MODE=sql|plan|existing, SMOKE_TRIP_ID, SMOKE_TOKEN,
# SMOKE_SIGNING_SECRET, SMOKE_DB_CONTAINER (see scripts/smoke.sh header).
#   make smoke                                         # dev stack, sql seed
#   make smoke BASE_URL=https://anemos.travel SMOKE_SEED_MODE=plan   # post-deploy
smoke: ## Run the end-to-end smoke test (BASE_URL, SMOKE_SEED_MODE, ...)
	@BASE_URL="$(if $(BASE_URL),$(BASE_URL),$(GATEWAY_URL))" \
		SMOKE_SEED_MODE="$(SMOKE_SEED_MODE)" SMOKE_TRIP_ID="$(SMOKE_TRIP_ID)" \
		SMOKE_TOKEN="$(SMOKE_TOKEN)" SMOKE_SIGNING_SECRET="$(SMOKE_SIGNING_SECRET)" \
		SMOKE_DB_CONTAINER="$(if $(SMOKE_DB_CONTAINER),$(SMOKE_DB_CONTAINER),$(GTT_PROJECT)-postgres-1)" \
		./scripts/smoke.sh

# Postgres backup — dumps the DB (gzip), prunes old dumps, writes the freshness
# heartbeat /admin/ops/health reads, and best-effort copies off-site via rclone.
# Wraps dockerize/production/backup.sh; every path/name overrides via env (see
# that script's header): BACKUP_DIR, RETENTION_DAYS, RCLONE_REMOTE,
# BACKUP_HEARTBEAT_FILE, COMPOSE_FILE, PG_SERVICE, PG_USER, PG_DB. On prod this
# runs via the goldentempo-backup systemd timer; this target is for manual/dry runs.
#   make backup                                        # prod defaults
#   make backup COMPOSE_FILE=dockerize/development/docker-compose.yml BACKUP_DIR=/tmp/bk
backup: ## Run a Postgres backup (BACKUP_DIR, RETENTION_DAYS, RCLONE_REMOTE, ...)
	@BACKUP_DIR="$(BACKUP_DIR)" RETENTION_DAYS="$(RETENTION_DAYS)" \
		RCLONE_REMOTE="$(RCLONE_REMOTE)" BACKUP_HEARTBEAT_FILE="$(BACKUP_HEARTBEAT_FILE)" \
		COMPOSE_FILE="$(COMPOSE_FILE)" COMPOSE_PROJECT="$(COMPOSE_PROJECT)" \
		PG_SERVICE="$(PG_SERVICE)" PG_USER="$(PG_USER)" PG_DB="$(PG_DB)" \
		./dockerize/production/backup.sh

# Documentation
docs: ## Show application URLs and documentation
	@echo "Application (via gateway):"
	@echo "  App (dev):       $(GATEWAY_URL)/"
	@echo "  App (deploy):    $(GATEWAY_URL)/app/"
	@echo "  API health:      $(GATEWAY_URL)/api/v1/health"
	@echo ""
	@echo "Documentation:"
	@echo "  Docker:          ./dockerize/README.md"
	@echo "  Main README:     ./README.md"
