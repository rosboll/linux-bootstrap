# linux-bootstrap — local checks.
# 'make lint'          — shellcheck on every .sh file in the repo.
# 'make smoke'         — desktop profile bootstrap in a Debian 13 container.
# 'make smoke-server'  — server profile bootstrap in a Debian 13 container.
# BOOTSTRAP_SMOKE=1 makes credential/hardware/systemd-user steps skip.

SHELL := /bin/bash

SCRIPTS := $(wildcard *.sh)
IMAGE   := linux-bootstrap-smoke
CONTAINER_RUNTIME ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

.PHONY: help lint smoke smoke-server smoke-build smoke-shell clean

help:
	@echo "Targets:"
	@echo "  lint          shellcheck all *.sh"
	@echo "  smoke         desktop profile (with --pentest) in a Debian 13 container"
	@echo "  smoke-server  server profile (with --pentest) in a Debian 13 container"
	@echo "  smoke-build   rebuild the smoke-test image"
	@echo "  smoke-shell   drop into the smoke-test container"
	@echo "  clean         remove the smoke-test image"

lint:
	@command -v shellcheck >/dev/null 2>&1 \
	    || { echo "shellcheck not installed (apt install shellcheck)"; exit 1; }
	shellcheck -x $(SCRIPTS)

smoke-build:
	@[ -n "$(CONTAINER_RUNTIME)" ] \
	    || { echo "Need podman or docker on PATH"; exit 1; }
	$(CONTAINER_RUNTIME) build -t $(IMAGE) -f Containerfile .

smoke: smoke-build
	$(CONTAINER_RUNTIME) run --rm -e BOOTSTRAP_SMOKE=1 \
	    --hostname bootstrap-smoke \
	    $(IMAGE) bash -lc './run-all.sh --pentest'

smoke-server: smoke-build
	$(CONTAINER_RUNTIME) run --rm -e BOOTSTRAP_SMOKE=1 \
	    --hostname bootstrap-smoke \
	    $(IMAGE) bash -lc './run-all.sh --server --pentest'

smoke-shell: smoke-build
	$(CONTAINER_RUNTIME) run --rm -it -e BOOTSTRAP_SMOKE=1 \
	    --hostname bootstrap-smoke \
	    $(IMAGE) bash -l

clean:
	-$(CONTAINER_RUNTIME) rmi $(IMAGE)
