EXTENSION = pg_inferal_relay
DATA = sql/pg_inferal_relay--0.1.0.sql

# PGXS (conditional: skipped when pg_config unavailable on host)
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs 2>/dev/null)
ifdef PGXS
include $(PGXS)
endif

# Docker testing
PG          ?= 18
PG_VERSIONS ?= 14 15 16 17 18
IMAGE        = pg_inferal_relay-test

docker-build:
	docker build --build-arg PG_VERSION=$(PG) \
	  -t $(IMAGE):$(PG) -f test/Dockerfile .

pg: docker-build
	@touch "$(CURDIR)/.psql_history"
	docker run --rm -it -p 50432:5432 -v "$(CURDIR):/repo" -v "$(CURDIR)/.psql_history:/root/.psql_history" $(DOCKER_ARGS) -w /repo \
	  $(IMAGE):$(PG) bash /repo/test/pg-start.sh psql -U postgres

test: docker-build
	docker run --rm -v "$(CURDIR):/repo" -w /repo \
	  $(IMAGE):$(PG) bash /repo/test/pg-start.sh \
	  sh -c 'pg_prove -U postgres -d postgres /repo/test/sql/*.sql'

test-all:
	@pass=""; fail=""; \
	for v in $(PG_VERSIONS); do \
	  echo ""; echo "=== PostgreSQL $$v ==="; \
	  if $(MAKE) -s test PG=$$v; then pass="$$pass $$v"; \
	  else fail="$$fail $$v"; fi; \
	done; \
	echo ""; echo "Results:"; \
	for v in $$pass; do echo "  ✓ PostgreSQL $$v"; done; \
	for v in $$fail; do echo "  ✗ PostgreSQL $$v FAILED"; done; \
	[ -z "$$fail" ]

tle:
	@mkdir -p dist
	bash scripts/build-tle.sh > dist/pg_inferal_relay--0.1.0-tle.sql
	@echo "dist/pg_inferal_relay--0.1.0-tle.sql"

.PHONY: docker-build pg test test-all tle
