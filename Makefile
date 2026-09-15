.PHONY: up down status health ingest test validate serve-web help

PYTHON := $(shell [ -x .venv/bin/python ] && echo .venv/bin/python || command -v python3)

help:
	@echo "Available commands:"
	@echo "  make up        - Start local sGTM (preview + live) with HTTPS proxy"
	@echo "  make down      - Stop local sGTM stack"
	@echo "  make status    - Show container status"
	@echo "  make health    - Check sGTM health endpoints"
	@echo "  make serve-web - Serve web/index.html on http://localhost:5500"
	@echo "  make ingest    - Run the CRM ingestion pipeline"
	@echo "  make test      - Run unit tests"
	@echo "  make validate  - Validate a sample payload against GA4 debug endpoint"

up:
	docker compose -f docker/docker-compose.yml --env-file .env up -d

down:
	docker compose -f docker/docker-compose.yml --env-file .env down

status:
	docker compose -f docker/docker-compose.yml --env-file .env ps

health:
	@curl -sk https://localhost:8888/healthy && echo " (live OK)" || echo "live server not ready"
	@curl -sk https://localhost:8889/healthy && echo " (preview OK)" || echo "preview server not ready"

serve-web:
	$(PYTHON) -m http.server 5500 --directory web

ingest:
	$(PYTHON) -m src.ingest

test:
	pytest tests/ -v

validate:
	$(PYTHON) -m src.send_ga4 --validate-sample
