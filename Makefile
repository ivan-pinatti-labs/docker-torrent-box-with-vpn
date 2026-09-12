# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
# GNU Make reads the whole file for rules before giving up on a missing
# include, so this rule lets *any* make target auto-create .env and
# certs/cert.conf from their .example on a fresh clone, instead of every
# invocation dying with "No rule to make target '.env'" before bootstrap ever
# runs. Deliberately no .example prerequisite here: with one, make compares
# mtimes and reruns seed-configs.sh (interactive skip/diff/replace prompt)
# whenever .example is newer than the live file, e.g. after a git pull, even
# though the live file already exists. Without a prerequisite, make only
# runs the recipe when the live file is missing outright; seed-configs.sh
# still checks for its .example itself and errors if that's absent.
# This is bare plumbing only: detecting UID/GID/TIMEZONE is a visible part of
# `make bootstrap` itself (see its recipe below), not a side effect of
# whichever target happens to run first, including check_requirements.
.env:
	@./scripts/seed-configs.sh .env

certs/cert.conf:
	@./scripts/seed-configs.sh certs/cert.conf

include .env certs/cert.conf

JELLYFIN_BASE_URL ?= /jellyfin
JELLYFIN_KNOWN_PROXY ?= $(NGINX_MEDIA_IP)

# CONTAINER_RUNTIME can be set in .env to 'podman' or 'docker'.
# If not set, auto-detect: Podman takes priority when available.
CONTAINER_RUNTIME ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)

ifeq ($(CONTAINER_RUNTIME),podman)
	RUNTIME := podman
	COMPOSE  := $(shell command -v podman-compose >/dev/null 2>&1 && echo podman-compose || echo "podman compose")
else
	RUNTIME := docker
	COMPOSE  := docker compose
endif

comma := ,
empty :=
space := $(empty) $(empty)

VPN_ON ?=
VPN_ON_LIST := $(strip $(subst $(comma),$(space),$(VPN_ON)))
VPN_ROUTE_SERVICES := bazarr flaresolverr lazylibrarian lidarr mylar prowlarr radarr readarr recyclarr sonarr whisparr
VPN_VALID_TOKENS := servarr $(VPN_ROUTE_SERVICES)
VPN_UNKNOWN_TOKENS := $(filter-out $(VPN_VALID_TOKENS),$(VPN_ON_LIST))
ifneq ($(VPN_UNKNOWN_TOKENS),)
$(error Unknown VPN_ON service(s) [$(VPN_UNKNOWN_TOKENS)]. Valid values are [$(VPN_VALID_TOKENS)])
endif
VPN_ROUTE_FILES := $(if $(filter servarr,$(VPN_ON_LIST)),docker-compose.routes/servarr-vpn.yml,$(foreach service,$(VPN_ROUTE_SERVICES),$(if $(filter $(service),$(VPN_ON_LIST)),docker-compose.routes/$(service)-vpn.yml)))
ROUTE_FILES ?= $(VPN_ROUTE_FILES)
COMPOSE_FILES := --file docker-compose.yml $(foreach route_file,$(ROUTE_FILES),--file $(route_file))
COMPOSE_PROJECT_NAME ?= $(notdir $(CURDIR))
# Exported, not just defined. The four shared networks are named
# ${COMPOSE_PROJECT_NAME}_<name> in both this file and the compose files, and
# compose only sees the value if it reaches the environment: a checkout whose
# .env does not set it would otherwise have make create `<dir>_apps` while
# compose looked up the fallback name, and `external: true` turns that
# mismatch into "network not found" rather than anything self-explanatory.
export COMPOSE_PROJECT_NAME
PODMAN_DOWN_TIMEOUT ?= 60

# How long scripts/assert-stack-started.sh waits for every enabled service to
# appear before calling the start failed. It polls alongside `compose up` rather
# than after it, so this bounds the stack, not the known hang in that command.
STACK_START_TIMEOUT ?= 300
export STACK_START_TIMEOUT

# Remembers the VPN_ON used by the last successful `make start`, so down/stop/restart
# match a running stack even when VPN_ON isn't repeated on the command line. An
# explicit VPN_ON on the command line always wins over the remembered value.
VPN_STATE_FILE := .vpn_on.state
LAST_VPN_ON := $(shell cat $(VPN_STATE_FILE) 2>/dev/null)
ifeq ($(origin VPN_ON),command line)
STOP_VPN_ON := $(VPN_ON)
else
STOP_VPN_ON := $(if $(LAST_VPN_ON),$(LAST_VPN_ON),$(VPN_ON))
endif
STOP_VPN_ON_LIST := $(strip $(subst $(comma),$(space),$(STOP_VPN_ON)))
STOP_ROUTE_FILES := $(if $(filter servarr,$(STOP_VPN_ON_LIST)),docker-compose.routes/servarr-vpn.yml,$(foreach service,$(VPN_ROUTE_SERVICES),$(if $(filter $(service),$(STOP_VPN_ON_LIST)),docker-compose.routes/$(service)-vpn.yml)))
STOP_COMPOSE_FILES := --file docker-compose.yml $(foreach route_file,$(STOP_ROUTE_FILES),--file $(route_file))

# One .PHONY per line, not a backslash continuation. checkmake reads only
# the first physical line of a .PHONY declaration and silently drops the
# rest, so a continuation makes it report restore-full, stop and test as
# undeclared when they are right here. Upstream: checkmake#280, fix open
# as checkmake#281. That fix reaches us only once it merges, checkmake
# releases it, and pre-commit-checklists moves its own checkmake pin to
# that release. Until then this form is load bearing. make treats the two
# forms identically.
.PHONY: all backup backup-configs backup-full backup-schedule bootstrap bootstrap_tests build_images clean clean_all check_requirements seed_all
.PHONY: configure_jellyfin_network configure_jdownloader2_api
.PHONY: detect_secrets_create_baseline down enable_test_profiles generate_certificate
.PHONY: heal_vpn_dependents
.PHONY: rotate_all rotate_api_keys rotate_certificate rotate_passwords wire_connections
.PHONY: disk_status korsync_users permissions_check permissions_repair permissions_smoke permissions_host_smoke prune_cache rotate_nginx_logs
.PHONY: storage_mount storage_unmount storage_status storage_install_boot storage_uninstall_boot storage_guard
.PHONY: install_requirements pull_docker_images pre_commit
.PHONY: restore-configs restore-full
.PHONY: restart sanity_fast sanity_full start start_library start_observability
.PHONY: stop stop_all update_containers update_pre_commit test test_ci test_extended test_prerequisites
.PHONY: test_no_rotate_passwords

BACKUP_DIR ?= backup
# Simply expanded, not ?=. The three archive names below each expand this,
# and a recursively expanded $(shell date) re-runs date on every expansion,
# so a run that straddles a second boundary gets two different timestamps in
# one backup. := runs date once. A command line override
# (make backup BACKUP_TIMESTAMP=...) still wins, same as before; only an
# environment variable of the same name no longer does.
BACKUP_TIMESTAMP := $(shell date +%Y-%m-%d-%H%M%S)
CONFIG_BACKUP_ARCHIVE := $(BACKUP_DIR)/configs-$(BACKUP_TIMESTAMP).tar.gz
FULL_BACKUP_ARCHIVE := $(BACKUP_DIR)/full-$(BACKUP_TIMESTAMP).tar.gz
RESTORE_SAFETY_ARCHIVE := $(BACKUP_DIR)/pre-restore-$(BACKUP_TIMESTAMP).tar.gz

# These patterns are unanchored, so a bare name matches that directory at ANY
# depth, not just at the top level. There is deliberately no `--exclude=data`
# here: every tar below archives `.env certs configs`, so the top-level media
# `data/` is never a candidate in the first place, and the pattern could only
# ever match nested ones. It silently excluded configs/jellyfin/config/data
# (Jellyfin's whole database: users, API keys, library) and configs/korsync/data
# from every backup this repo has ever taken, which was discovered the worst
# possible way, when a restore could not put them back. `cache` and `logs`
# below are unanchored on purpose: dropping those at any depth is intended.
#
# Comments have to live here rather than beside the flag they describe: the
# list below is one backslash-continued logical line, so a `#` among the flags
# would comment out every exclude after it and silently shrink this list.
#
# By the same token, a name here only earns its place if it can appear *under*
# `.env`, `certs` or `configs`. An exclude for a top-level directory does
# nothing, because a top-level directory is never handed to tar to begin with.
COMMON_BACKUP_EXCLUDES := \
	--exclude=.git \
	--exclude=.codex \
	--exclude=.pytest_cache \
	--exclude=.ruff_cache \
	--exclude='*.log' \
	--exclude='*.log.*' \
	--exclude='*.pid' \
	--exclude=cache \
	--exclude=logs \
	--exclude=node_modules \
	--exclude=storage \
	--exclude=tests \
	--exclude='configs/*/config/.aspnet' \
	--exclude='configs/*/config/asp' \
	--exclude='configs/*/config/logs' \
	--exclude='configs/*/config/*/logs'

# The only paths tar is allowed to silently omit. All are container-owned
# runtime state that the host user genuinely cannot read and that no restore
# needs: calibre's PulseAudio runtime directory, its cache, and jdownloader2's
# generated webauth-htpasswd. Anything else going missing means the archive is
# not what it claims to be.
BACKUP_SKIPPABLE := (/\.config/pulse|/\.cache/|webauth-htpasswd)

# Runs one archive creation and refuses to call a partial result a success.
# --ignore-failed-read is what stops a single unreadable container-owned file
# from aborting the whole run, but it also makes tar exit 0 after omitting
# things, so the exit code alone cannot be trusted. This reads back what tar
# reported skipping and fails on anything outside BACKUP_SKIPPABLE, which is
# the difference between tolerating a pulse socket and quietly dropping a
# database. LC_ALL=C because those diagnostics are what gets matched: under a
# localized tar the English pattern finds nothing, every skip reads as clean,
# and the check silently stops checking. Args: 1 archive path, 2 exclude flags.
define create_archive_checked
	@errlog="$$(mktemp)"; \
	LC_ALL=C tar --create --gzip --warning=no-file-ignored --ignore-failed-read \
		--file "$(1)" $(2) .env certs configs 2>"$$errlog"; \
	status=$$?; \
	cat "$$errlog" >&2; \
	unexpected="$$(grep -E 'Cannot (open|stat|read)' "$$errlog" \
		| grep -vE '$(BACKUP_SKIPPABLE)' || true)"; \
	rm -f "$$errlog"; \
	if [ "$$status" -ne 0 ]; then exit "$$status"; fi; \
	if [ -n "$$unexpected" ]; then \
		echo "ERROR: $(1) omitted files that are not known-skippable:"; \
		echo "$$unexpected"; \
		echo "Refusing to report an incomplete archive as complete."; \
		exit 1; \
	fi
endef

# Post-condition on the finished archive, complementing the check above: that
# one watches what tar reported, this one checks what actually landed. A tree
# absent entirely is broken beyond argument, and for restore-configs this is
# the last thing standing between a bad safety archive and the `rm -rf`.
define verify_archive_complete
	@for required in .env certs configs; do \
		tar --list --gzip --file "$(1)" 2>/dev/null \
			| grep -qE "^$$required(/|$$)" || { \
			echo "ERROR: $(1) is missing '$$required'."; \
			echo "The archive is incomplete and will not be treated as usable."; \
			exit 1; \
		}; \
	done
endef

CONFIG_BACKUP_EXCLUDES := $(COMMON_BACKUP_EXCLUDES) \
	--exclude='*.db-shm' \
	--exclude='*.db-wal' \
	--exclude='*.json.bak' \
	--exclude='*.sqlite-shm' \
	--exclude='*.sqlite-wal' \
	--exclude='configs/*/config.bak' \
	--exclude='configs/*/config.v*.bak' \
	--exclude='configs/*/config/Backups' \
	--exclude='configs/*/config/MediaCover' \
	--exclude='configs/*/config/Sentry' \
	--exclude='configs/*/config/logs.db' \
	--exclude='configs/jellyfin/cache' \
	--exclude='configs/jellyfin/config/cache' \
	--exclude='configs/jellyfin/config/metadata' \
	--exclude='configs/recyclarr/config/resources/*/git'

all: generate_certificate pull_docker_images start

# configs/flaresolverr/config/chromedriver is bind-mounted as a specific file
# (not the whole directory: see docker-compose-servarr.yml) so a working
# binary survives container recreation instead of being re-downloaded and
# re-patched every time. On a fresh clone this path doesn't exist, which
# breaks in two different ways depending what's there:
#   - missing entirely: podman auto-vivifies a directory at the mount point,
#     which fails the mount at container start.
#   - present but empty: FlareSolverr's own utils.py checks only
#     `os.path.exists("/app/chromedriver")` to decide whether it's already
#     running the image's pre-baked driver, so it never re-downloads; it
#     just tries to exec the empty file and crashes with "Exec format error".
# The only fix is to seed a real binary before first start. It has to be the
# image's own bundled chromedriver: that's the exact build FlareSolverr's
# undetected_chromedriver patches in place on first successful run (verified
# by extracting /app/chromedriver from the pinned image and comparing it
# against an already-working install: same file, pre-patch).
configs/flaresolverr/config/chromedriver:
	@mkdir -p configs/flaresolverr/config
	@if [ ! -s configs/flaresolverr/config/chromedriver ]; then \
		echo "[configs/flaresolverr/config/chromedriver] Extracting from the flaresolverr image..."; \
		$(RUNTIME) run --rm --entrypoint cat "docker.io/flaresolverr/flaresolverr:$(FLARESOLVERR_VERSION)" /app/chromedriver \
			> configs/flaresolverr/config/chromedriver; \
		chmod 755 configs/flaresolverr/config/chromedriver; \
		echo "[configs/flaresolverr/config/chromedriver] Seeded from the flaresolverr image."; \
	fi

# Split out of bootstrap so anything that needs a fully seeded tree without
# the rest of bootstrap's own steps (VPN credential prompts, certificate
# generation, starting the stack) can depend on just this. CI's own
# integration job is the reason this exists: it calls make start directly
# rather than make bootstrap, and without this, every app whose compose
# service references a secrets.yml/.env.secrets file that's normally seeded
# here fails outright the moment that file doesn't exist yet.
#
# configs/gluetun/.env is deliberately absent from the seed-configs.sh list
# below, unlike every other app's config: seed-gluetun-secret.sh already
# seeds it earlier in bootstrap's own recipe, since a Proton VPN setup needs
# to edit it right away. Seeding it again later would hit seed-configs.sh's
# already-exists prompt on every single bootstrap run.
seed_all: configs/flaresolverr/config/chromedriver
	@echo "Remapping directory ownership into the container user namespace..."
	@echo "  (rootless Podman: host uid maps to uid=0 inside containers;"
	@echo "   app processes run as service-specific non-root UIDs)"
	@mkdir -p \
		configs/audiobookshelf/metadata/backups \
		configs/flaresolverr/config \
		data/media \
		data/media/calibre-library \
		data/recycle \
		data/torrents/blackhole \
		data/torrents \
		data/usenet/blackhole \
		storage/loki/data \
		storage/prometheus/data \
		storage/grafana/data
	@touch data/torrents/blackhole/.gitkeep data/usenet/blackhole/.gitkeep
	@./scripts/seed-calibre-library.sh
	@./scripts/seed-secrets.sh configs/grafana
	@./scripts/seed-secrets.sh configs/qbittorrent
	@./scripts/seed-secrets.sh configs/qbittorrent_exporter
	@./scripts/seed-secrets.sh configs/homepage
	@./scripts/seed-secrets.sh configs/calibre
	@./scripts/seed-secrets.sh configs/nzbget
	@./scripts/seed-secrets.sh configs/sabnzbd
	@./scripts/seed-secrets.sh configs/jdownloader2
	@./scripts/seed-secrets.sh configs/sonarr
	@./scripts/seed-secrets.sh configs/radarr
	@./scripts/seed-secrets.sh configs/readarr
	@./scripts/seed-secrets.sh configs/bazarr
	@./scripts/seed-secrets.sh configs/prowlarr
	@./scripts/seed-secrets.sh configs/lidarr
	@./scripts/seed-secrets.sh configs/whisparr
	@./scripts/seed-secrets.sh configs/mylar
	@./scripts/seed-secrets.sh configs/jellyfin
	@./scripts/seed-secrets.sh configs/audiobookshelf
	@./scripts/seed-secrets.sh configs/calibre-web
	@./scripts/seed-configs.sh configs/grafana/.env
	@./scripts/seed-configs.sh configs/grafana/config/grafana.ini
	@./scripts/seed-configs.sh configs/sonarr/config/config.xml
	@./scripts/seed-configs.sh configs/radarr/config/config.xml
	@./scripts/seed-configs.sh configs/lidarr/config/config.xml
	@./scripts/seed-configs.sh configs/readarr/config/config.xml
	@./scripts/seed-configs.sh configs/prowlarr/config/config.xml
	@./scripts/seed-configs.sh configs/whisparr/config/config.xml
	@./scripts/seed-configs.sh configs/jellyfin/config/network.xml
	@./scripts/seed-configs.sh configs/lazylibrarian/config/config.ini
	@./scripts/seed-configs.sh configs/mylar/config/mylar/config.ini
	@./scripts/seed-configs.sh configs/jackett/config/Jackett/ServerConfig.json
	@./scripts/seed-configs.sh configs/nzbhydra2/config/nzbhydra.yml
	@./scripts/seed-configs.sh configs/qbittorrent/config/qBittorrent/qBittorrent.conf
	@./scripts/seed-configs.sh configs/calibre-web/config/client_secrets.json
	@./scripts/seed-configs.sh configs/notifiarr/.env
	@./scripts/seed-configs.sh configs/sabnzbd/config/sabnzbd.ini
	@./scripts/seed-configs.sh configs/bazarr/config/config/config.yaml
	@./scripts/seed-configs.sh configs/calibre/config/.config/calibre/gui.json
	@./scripts/seed-configs.sh configs/calibre/config/.config/calibre/gui.py.json
	@./scripts/seed-configs.sh configs/calibre/config/.config/calibre/global.py.json
	@./scripts/seed-configs.sh configs/calibre/config/.config/calibre/dynamic.pickle.json
	@./scripts/seed-configs.sh configs/recyclarr/config/recyclarr.yml
	@./scripts/seed-configs.sh configs/recyclarr/config/secrets.yml
	@./scripts/permissions.py repair --runtime $(RUNTIME) --recursive

bootstrap: configs/flaresolverr/config/chromedriver
	@echo "Detecting UID/GID/TIMEZONE for .env..."
	@./scripts/detect-system-values.sh .env
	@echo "Checking Gluetun VPN credentials..."
	@./scripts/seed-gluetun-secret.sh
	@./scripts/seed-nginx-ports.sh
	@$(MAKE) --no-print-directory seed_all
	@if [ -f "$(CERTIFICATES_FOLDER)/server.pfx" ]; then \
		echo "Certificate already exists at $(CERTIFICATES_FOLDER)/server.pfx, skipping generation (keeps a custom certificate you supplied yourself)."; \
	else \
		echo "Generating the self-signed certificate..."; \
		$(MAKE) --no-print-directory generate_certificate; \
	fi
	@echo "Building custom images (LazyLibrarian, Mylar)..."
	@$(MAKE) --no-print-directory build_images
	@echo "Starting the stack for the first time..."
	@$(MAKE) --no-print-directory start
	@echo "Waiting for Gluetun to establish the VPN connection..."
	@elapsed=0; status=""; \
	while [ "$$elapsed" -lt 90 ]; do \
		status="$$($(COMPOSE) $(COMPOSE_FILES) --profile enabled exec -T gluetun wget -qO- http://127.0.0.1:8000/v1/vpn/status 2>/dev/null | grep -o '"running"')"; \
		[ -n "$$status" ] && break; \
		sleep 5; elapsed=$$((elapsed + 5)); \
	done; \
	if [ -z "$$status" ]; then \
		echo "ERROR: Gluetun did not report a running VPN connection after 90s."; \
		echo "This usually means the WireGuard key in configs/gluetun/.secret is wrong,"; \
		echo "or the provider/server settings in configs/gluetun/.env don't match your"; \
		echo "account. Check 'podman logs $(CONTAINER_PREFIX)gluetun' for the exact reason, fix"; \
		echo "configs/gluetun/.env or .secret, then re-run 'make bootstrap'."; \
		exit 1; \
	fi
	@echo "Gluetun VPN connection established."
	@echo "Applying Jellyfin network settings now that it has generated its config..."
	@$(MAKE) --no-print-directory configure_jellyfin_network
	@echo "Opening jDownloader2's API to Mylar now that it has generated its config..."
	@$(MAKE) --no-print-directory configure_jdownloader2_api
	@echo "Wiring app-to-app connections..."
	@$(MAKE) --no-print-directory wire_connections
	@echo "Rotating every seeded API key and password..."
	@$(MAKE) --no-print-directory rotate_all
	@echo "Bootstrap complete: the stack is running, wired, and every credential"
	@echo "has been rotated away from its seeded default. See docs/CONNECTIONS.md"
	@echo "for what was wired, and docs/ROTATION.md to rotate again later."
	@if [ "$(NGINX_PROFILE)" = "enabled" ] && [ "$(HOMEPAGE_PROFILE)" = "enabled" ]; then \
		echo ""; \
		https_port="$$(grep -m1 '^NGINX_HTTPS_PORT=' .env | cut -d= -f2-)"; \
		if [ "$$https_port" = "443" ]; then \
			echo "Open https://$(DOMAIN)/ for the dashboard with links to every app."; \
		else \
			echo "Open https://$(DOMAIN):$$https_port/ for the dashboard with links to every app."; \
		fi; \
	fi

# `backup` is an alias for `backup-configs`: the lean archive is the right
# default for routine backups. Both restore through the same `restore-configs`
# target (`restore-full` is just an alias for it too); a full backup is only
# worth the extra size if you actually need the things it keeps that the lean
# one strips: Jellyfin's metadata library and Recyclarr's cloned git repos.
# Caches are not among them. --exclude=cache in COMMON_BACKUP_EXCLUDES is
# unanchored, so both modes drop every directory named cache wherever it sits.
# *arr MediaCover artwork and scheduled backups are no longer among them: both
# now live under data/ (MEDIA_COVERS_FOLDER and APP_BACKUPS_FOLDER), so neither
# mode archives them. The excludes below are kept for setups predating that
# move. See docs/STORAGE.md.
backup: backup-configs

backup-configs:
	@echo "Config backup (lean): .env, certs, configs, minus logs, caches, and artwork."
	@echo "For everything the lean backup strips, run: make backup-full"
	@mkdir -p "$(BACKUP_DIR)"
	$(call create_archive_checked,$(CONFIG_BACKUP_ARCHIVE),$(CONFIG_BACKUP_EXCLUDES))
	$(call verify_archive_complete,$(CONFIG_BACKUP_ARCHIVE))
	@echo "Done: $(CONFIG_BACKUP_ARCHIVE) ($$(du -h "$(CONFIG_BACKUP_ARCHIVE)" | cut -f1))"

backup-full:
	@echo "Config backup (full): .env, certs, configs, keeping Jellyfin metadata"
	@echo "and Recyclarr's cloned git repos that backup-configs strips."
	@mkdir -p "$(BACKUP_DIR)"
	$(call create_archive_checked,$(FULL_BACKUP_ARCHIVE),$(COMMON_BACKUP_EXCLUDES))
	$(call verify_archive_complete,$(FULL_BACKUP_ARCHIVE))
	@echo "Done: $(FULL_BACKUP_ARCHIVE) ($$(du -h "$(FULL_BACKUP_ARCHIVE)" | cut -f1))"

# Installs a cron entry that runs `make backup` on a schedule (default:
# daily at 03:00). Prompts for frequency and time in a real terminal;
# see scripts/schedule-backup.sh for the non-interactive fallback.
backup-schedule:
	@./scripts/schedule-backup.sh

restore-configs:
	@if [ -z "$(BACKUP)" ]; then echo "ERROR: BACKUP=/path/to/archive.tar.gz is required"; exit 1; fi
	@if [ ! -f "$(BACKUP)" ]; then echo "ERROR: backup archive not found: $(BACKUP)"; exit 1; fi
	@echo "Creating pre-restore safety backup at $(RESTORE_SAFETY_ARCHIVE)..."
	@mkdir -p "$(BACKUP_DIR)"
	# Same excludes as backup-full: without them this archives every cache and
	# artwork directory, which is what makes it minutes slower than the backup
	# targets it is meant to mirror. create_archive_checked tolerates only the
	# container-owned runtime files in BACKUP_SKIPPABLE and fails on anything
	# else, which matters most here: everything below this line is destructive.
	$(call create_archive_checked,$(RESTORE_SAFETY_ARCHIVE),$(COMMON_BACKUP_EXCLUDES))
	$(call verify_archive_complete,$(RESTORE_SAFETY_ARCHIVE))
	@echo "Restoring $(BACKUP)..."
	@rm -rf .env certs configs
	@tar --extract --gzip --file "$(BACKUP)" --directory .
	@echo ".OK!"

restore-full: restore-configs

clean:
	@echo "Stopping and removing containers (if they are running)..."
	@$(COMPOSE) $(COMPOSE_FILES) --profile enabled down

	@echo "Reverting git files to original"
	@sudo git clean -fdx

	@echo -n "Cleaning Certs folders........."
	@cd certs && find . ! -name '.gitignore' -type f -exec sudo rm -f {} + && cd ..
	@echo ".OK!"

	@echo -n "Cleaning Download folders........."
	@for dir in data/downloads data/torrents data/usenet; do \
		[ -d "$$dir" ] && find "$$dir" ! -name '.gitkeep' -type f -exec sudo rm -f {} + ; \
	done
	@echo ".OK!"

clean_all: clean
	@echo -n "Cleaning Media folders........."
	@[ -d data/media ] && find data/media -path data/media/calibre-library -prune -o \
		! -name '.gitkeep' -type f -exec sudo rm -f {} +
	@echo ".OK!"

check_requirements:
	make --version
	@echo
	@(command -v podman && podman --version) || docker --version
	@echo
	@(command -v podman-compose && podman-compose --version) || docker compose version
	@echo
	yq --version
	@echo
	xmlstarlet --version
	@echo
	uname --kernel-release
	@echo
	@modinfo wireguard 2>/dev/null || lsmod | grep wireguard || echo "WARNING: WireGuard module not loaded"

detect_secrets_create_baseline:
	@echo -n "Creating detect-secrets baseline file........."
	@detect-secrets scan > .secrets.baseline
	@echo ".OK!"

down:
	@echo "Stopping containers (if they are running)..."
	@if [ "$(RUNTIME)" = "podman" ]; then \
		project_filter="label=com.docker.compose.project=$(COMPOSE_PROJECT_NAME)"; \
		project_containers="$$(podman ps --all --filter "$$project_filter" --format "{{.Names}}")"; \
		if [ -z "$$project_containers" ]; then \
			echo "No stack containers found."; \
		else \
			running_containers="$$(podman ps --filter "$$project_filter" --format "{{.Names}}")"; \
			if [ -n "$$running_containers" ]; then \
				echo "$$running_containers" | xargs -r podman kill --signal TERM >/dev/null || true; \
				elapsed=0; \
				while [ "$$elapsed" -lt "$(PODMAN_DOWN_TIMEOUT)" ]; do \
					remaining="$$(podman ps --filter "$$project_filter" --format "{{.Names}}")"; \
					[ -z "$$remaining" ] && break; \
					sleep 1; \
					elapsed=$$((elapsed + 1)); \
				done; \
				remaining="$$(podman ps --filter "$$project_filter" --format "{{.Names}}")"; \
				if [ -n "$$remaining" ]; then \
					echo "Force-killing containers still running after $(PODMAN_DOWN_TIMEOUT)s..."; \
					echo "$$remaining" | xargs -r podman kill >/dev/null || true; \
				fi; \
			fi; \
			echo "$$project_containers" | grep -vx $(CONTAINER_PREFIX)gluetun | xargs -r podman rm --force --time 0 >/dev/null || true; \
			echo "$$project_containers" | grep -x $(CONTAINER_PREFIX)gluetun | xargs -r podman rm --force --time 0 >/dev/null || true; \
			for network in edge wan apps services media observability; do \
				podman network rm "$(COMPOSE_PROJECT_NAME)_$$network" >/dev/null 2>&1 || true; \
			done; \
		fi; \
	else \
		$(COMPOSE) $(STOP_COMPOSE_FILES) --profile enabled down --timeout 60; \
	fi
	@rm -f $(VPN_STATE_FILE)

# configs/jellyfin/config/network.xml is seeded from network.xml.example
# like every other app's config now (confirmed live: Jellyfin preserves a
# pre-seeded network.xml byte for byte on its genuine first boot instead of
# overwriting it), with BaseUrl/EnableHttps/CertificatePath/KnownProxies
# already set to their .env.example-matching defaults, and
# CertificatePassword patched by generate_certificate before the stack ever
# starts, exactly like Lidarr/Prowlarr/Radarr/Readarr/Sonarr/Whisparr. This
# target is now only needed to correct drift from a non-default
# JELLYFIN_BASE_URL or NGINX_MEDIA_IP; bootstrap still calls it automatically
# after `make start` as an idempotent safety net, and it's a clean no-op
# when nothing has drifted.
#
# EnableHttps/CertificatePath: without them, the compose file's own
# JELLYFIN_HTTPS_PORT publish (8920) would sit completely unused -- direct
# LAN access to Jellyfin (distinct from nginx's already-HTTPS /jellyfin/
# proxy path) would be plaintext-only with an exposed-but-dead encrypted
# port next to it. RequireHttps deliberately stays false and
# JELLYFIN_PublishedServerUrl (in docker-compose-media-library.yml)
# deliberately stays http://: some Jellyfin client apps, smart TVs
# especially, handle a self-signed/custom-CA certificate poorly, so forcing
# HTTPS-only could break direct playback on real devices. This only makes
# the encrypted port actually usable alongside the existing plaintext one,
# not exclusive.
configure_jellyfin_network:
	@echo "Configuring Jellyfin network settings..."
	@if [ "$(RUNTIME)" = "podman" ]; then runner="podman unshare"; else runner=""; fi; \
	$$runner xmlstarlet --quiet ed --inplace \
		--update '/NetworkConfiguration/BaseUrl' --value "$(JELLYFIN_BASE_URL)" \
		--delete '/NetworkConfiguration/KnownProxies/string' \
		--subnode '/NetworkConfiguration/KnownProxies' --type elem --name string --value "$(JELLYFIN_KNOWN_PROXY)" \
		--update '/NetworkConfiguration/CertificatePassword' --value "${CERT_PASSWORD}" \
		--update '/NetworkConfiguration/CertificatePath' --value "/certs/server.pfx" \
		--update '/NetworkConfiguration/EnableHttps' --value "true" \
		"configs/jellyfin/config/network.xml"

# jDownloader2 restricts its REST API and its older /jd namespace (the one
# Mylar's connection test needs) to loopback by default, and disables the
# /jd namespace outright until deprecatedapienabled is turned on. This
# can't be seeded the way Jellyfin's network.xml is: the base image only
# populates /config/cfg with its full set of default files if that
# directory does not already exist yet
# (`[ -d /config/cfg ] || cp -rv /defaults/cfg /config/cfg` in its own
# 55-jdownloader2.sh init script), so pre-seeding even one file there stops
# every other default file, including one read on every boot, from ever
# being created, and jDownloader2 crash-loops forever. This has to run
# after jDownloader2's own first boot instead, against the file it just
# generated itself. See docs/JDOWNLOADER2.md.
configure_jdownloader2_api:
	@if [ "$(JDOWNLOADER2_PROFILE)" != "enabled" ]; then \
		echo "jDownloader2 is disabled in .env, skipping its API configuration."; \
		exit 0; \
	fi; \
	echo "Configuring jDownloader2's API access..."; \
	target="configs/jdownloader2/config/cfg/org.jdownloader.api.RemoteAPIConfig.json"; \
	elapsed=0; \
	while [ ! -f "$$target" ] && [ "$$elapsed" -lt 60 ]; do \
		sleep 2; elapsed=$$((elapsed + 2)); \
	done; \
	if [ ! -f "$$target" ]; then \
		echo "ERROR: $$target was not created after 60s; jDownloader2 may have failed to start."; \
		exit 1; \
	fi; \
	$(COMPOSE) $(COMPOSE_FILES) --profile enabled stop jdownloader2; \
	if [ "$(RUNTIME)" = "podman" ]; then runner="podman unshare"; else runner=""; fi; \
	$$runner sh -c "jq -c '.externinterfaceenabled = true | .externinterfacelocalhostonly = false | .deprecatedapienabled = true | .deprecatedapilocalhostonly = false | .deprecatedapiport = 3128' '$$target' > '$$target.tmp' && mv '$$target.tmp' '$$target'"; \
	$(COMPOSE) $(COMPOSE_FILES) --profile enabled start jdownloader2

# Patches the certificate password into one app's config and reports what
# actually happened. These lines used to be `<edit>; echo OK!`, where the `;`
# printed OK whatever the edit did: confirmed live, a missing
# configs/nzbhydra2/config/nzbhydra.yml printed xmlstarlet's own "no such file"
# error and then "OK!" on the very next line, so the run claimed to have set a
# password it had not set.
#
# A config that simply is not there yet is reported as skipped rather than
# failing the target, because that is a legitimate state: a disabled profile
# never gets seeded, and `make bootstrap` calls this before every app has a
# live config. An edit that genuinely fails still stops the run.
define patch_cert_xml
	@printf '%-14s' "$(1)..."; \
	if [ ! -f "$(2)" ]; then \
		echo "skipped (no config yet)"; \
	elif xmlstarlet --quiet ed --inplace --update '$(3)' --value "${CERT_PASSWORD}" "$(2)"; then \
		echo "OK!"; \
	else \
		echo "FAILED"; \
		exit 1; \
	fi
endef

define patch_cert_nzbhydra
	@printf '%-14s' "$(1)..."; \
	if [ ! -f "$(2)" ]; then \
		echo "skipped (no config yet)"; \
	elif sslKey="${CERT_PASSWORD}" yq -i '(.main.sslKeyStorePassword) = strenv(sslKey)' "$(2)"; then \
		echo "OK!"; \
	else \
		echo "FAILED"; \
		exit 1; \
	fi
endef

generate_certificate:
	@if [ "$(LAN_IP)" = "192.168.1.x" ]; then \
		echo "ERROR: LAN_IP in .env is still the example placeholder (192.168.1.x)."; \
		echo "OpenSSL rejects it as an invalid IP address in the certificate's"; \
		echo "subjectAltName. Set LAN_IP to your host's real LAN address in .env,"; \
		echo "then re-run 'make generate_certificate'."; \
		exit 1; \
	fi
	@echo -n "Generating self-signed certificate..."
	@openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
		-subj "/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_CITY}/O=${CERT_ORGANIZATION}/OU=${CERT_OU}/CN=${CERT_FQDN}" \
		-addext "subjectAltName = DNS:${CERT_FQDN}, DNS:${JELLYFIN_PROXY_DOMAIN}, DNS:localhost, IP:127.0.0.1, IP:${LAN_IP}, IP:${GLUETUN_SERVICES_IP}, IP:${GLUETUN_OBSERVABILITY_IP}" \
		-keyout certs/server.key -out certs/server.crt
	@openssl pkcs12 -export -out ${CERTIFICATES_FOLDER}/server.pfx -inkey ${CERTIFICATES_FOLDER}/server.key -in ${CERTIFICATES_FOLDER}/server.crt -password pass:${CERT_PASSWORD}
	# openssl writes server.key and server.pfx as 600 regardless of umask,
	# since both contain private key material. Many services here read them
	# as a container UID that isn't the owner, so all three must be 644 (see
	# the "Use your own certificate" note in the README); without this,
	# whichever service's crypto stack cares about read access fails at
	# startup with an opaque low-level I/O error rather than "permission
	# denied", e.g. Sonarr's ValidateSslCertificate: "BIO routines::system lib".
	@chmod 644 certs/server.key certs/server.crt certs/server.pfx
	@echo Hash for the certificate is...
	@openssl x509 -noout -fingerprint -sha256 -inform pem -in ${CERTIFICATES_FOLDER}/server.crt
	@echo Updating certificate password in Apps configs...
	$(call patch_cert_xml,Lidarr,configs/lidarr/config/config.xml,/Config/SslCertPassword)
	$(call patch_cert_xml,Prowlarr,configs/prowlarr/config/config.xml,/Config/SslCertPassword)
	$(call patch_cert_xml,Radarr,configs/radarr/config/config.xml,/Config/SslCertPassword)
	$(call patch_cert_xml,Readarr,configs/readarr/config/config.xml,/Config/SslCertPassword)
	$(call patch_cert_xml,Sonarr,configs/sonarr/config/config.xml,/Config/SslCertPassword)
	$(call patch_cert_xml,Whisparr,configs/whisparr/config/config.xml,/Config/SslCertPassword)
	$(call patch_cert_xml,Jellyfin,configs/jellyfin/config/network.xml,/NetworkConfiguration/CertificatePassword)
	$(call patch_cert_nzbhydra,NZBHydra,configs/nzbhydra2/config/nzbhydra.yml)

rotate_certificate:
	@./scripts/rotate-certificate.sh

install_requirements:
	@echo "Installing requirements..."
	@echo "Recommended: Podman (rootless, daemonless, more secure than Docker)"
	@echo "  Fedora/RHEL:  sudo dnf install podman podman-compose xmlstarlet wireguard-tools"
	@echo "  Debian/Ubuntu: sudo apt install podman podman-compose xmlstarlet wireguard"
	@echo ""
	@echo "Alternative: Docker"
	@echo "  sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras xmlstarlet wireguard"
	@echo ""
	@echo "yq: https://github.com/mikefarah/yq#install  (or via asdf: asdf install)"

pre_commit:
	@echo "Running pre-commit checks..."
	@pre-commit run --all-files

disk_status:
	@./scripts/disk-status.sh

# External storage (see docs/STORAGE.md). All settings come from .env's
# ### EXTERNAL STORAGE block; these are inert while STORAGE_REMOTE is empty.
storage_mount:
	@./scripts/storage-mount.sh mount

storage_unmount:
	@./scripts/storage-mount.sh unmount

storage_status:
	@./scripts/storage-mount.sh status

storage_install_boot:
	@./scripts/storage-mount.sh install-boot

storage_uninstall_boot:
	@./scripts/storage-mount.sh uninstall-boot

korsync_users:
	@./scripts/korsync-users.sh $(ARGS)

permissions_check:
	@./scripts/permissions.py check --runtime $(RUNTIME)

permissions_repair:
	@./scripts/permissions.py repair --runtime $(RUNTIME) --recursive

permissions_smoke:
	@./scripts/permissions.py smoke --runtime $(RUNTIME)

permissions_host_smoke:
	@./scripts/permissions.py host-smoke --runtime $(RUNTIME)

rotate_nginx_logs:
	@./scripts/rotate-nginx-logs.sh

prune_cache:
	@./scripts/prune-nginx-cache.sh

sanity_fast:
	@echo "Running fast sanity checks..."
	@pre-commit run --all-files

sanity_full: sanity_fast
	@echo "Running full push checks (history secret scan, checkov, trivy, links)..."
	@SKIP=all-files-sweep pre-commit run --all-files --hook-stage pre-push

build_images:
	@echo "Building custom container images..."
	@$(COMPOSE) $(COMPOSE_FILES) --profile enabled build lazylibrarian mylar

pull_docker_images:
	@echo "Pulling container images..."
	@$(COMPOSE) $(COMPOSE_FILES) --profile enabled pull

# Blocks until gluetun is actually up, and says why when it never gets there.
# Both halves of the condition matter: a stopped container keeps reporting the
# health status it had when it stopped, so matching on health alone passes
# instantly against an exited gluetun (confirmed live: status=exited with
# health=healthy). Everything using network_mode: container:gluetun would then
# be started against a namespace that no longer exists.
# The bare timeout only ever printed "did not become healthy in time", which
# says nothing about whether the endpoint was unreachable, the key was rejected,
# or the container had already exited. Diagnosing one CI occurrence meant
# diffing two whole runs line by line to notice gluetun took 5s on the run that
# worked and gave up at 120s on the one that did not. The state line and the
# tail of gluetun's own log answer that in place.
# Waits on gluetun's own health endpoint as well as the container's health
# status, and treats either as ready.
#
# Podman runs healthchecks from transient systemd timers, and where that
# plumbing is unavailable the status simply stays "starting" forever. CI hit
# exactly that: gluetun's log showed the tunnel up and the public IP fetched
# about a second after start, while podman still reported health=starting two
# minutes later. Waiting only on the container status turns a working gateway
# into a failed build.
#
# The probe is the same request the compose healthcheck makes, run directly,
# so this is not a weaker check. It just does not depend on whether anything
# scheduled it.
define wait_for_gluetun
	@echo "Waiting for VPN gateway to be healthy (up to 180s)..."
	@timeout 180 sh -c 'until $(RUNTIME) inspect $(CONTAINER_PREFIX)gluetun --format "{{.State.Running}} {{.State.Health.Status}}" 2>/dev/null | grep -qx "true healthy" \
		|| { $(RUNTIME) inspect $(CONTAINER_PREFIX)gluetun --format "{{.State.Running}}" 2>/dev/null | grep -qx true \
			&& $(RUNTIME) exec $(CONTAINER_PREFIX)gluetun wget -q -O /dev/null http://127.0.0.1:9999/ 2>/dev/null; }; do sleep 5; done' || { \
		echo "ERROR: gluetun did not become healthy in time"; \
		echo "--- gluetun state ---"; \
		$(RUNTIME) inspect $(CONTAINER_PREFIX)gluetun \
			--format 'status={{.State.Status}} health={{.State.Health.Status}} exitcode={{.State.ExitCode}}' \
			2>/dev/null || echo "(gluetun could not be inspected; it may never have been created)"; \
		echo "--- gluetun log, last 40 lines ---"; \
		$(RUNTIME) logs --tail 40 $(CONTAINER_PREFIX)gluetun 2>&1 || echo "(no logs available)"; \
		exit 1; \
	}
endef

# podman-compose restarts every service concurrently with no dependency ordering
# (see transfer_service_status() in podman_compose.py), so services using
# network_mode: container:gluetun would race gluetun's own restart and could be
# left attached to its old, torn down network namespace. Restart gluetun first,
# wait for it to be healthy again, then restart everything else.
restart:
	@echo "Restarting VPN gateway..."
	@$(COMPOSE) $(STOP_COMPOSE_FILES) --profile enabled restart gluetun
	$(call wait_for_gluetun)
	@echo "Restarting remaining containers..."
	@services=$$($(COMPOSE) $(STOP_COMPOSE_FILES) --profile enabled config --services 2>/dev/null | grep -vx gluetun); \
	$(COMPOSE) $(STOP_COMPOSE_FILES) --profile enabled restart $$services

# gluetun's own `restart: unless-stopped` policy can also fire it back up on
# its own (lost WireGuard handshake, OOM kill, etc.) outside of `make
# restart` entirely. `depends_on: restart: true` in the compose files is
# meant to cover exactly this, but podman-compose (checked through 1.6.0,
# the latest release) only ever reads the `condition` key and silently
# ignores `restart`, so nothing actually restarts these containers when that
# happens. Detect and fix it after the fact: any container sharing gluetun's
# network namespace whose StartedAt predates gluetun's current StartedAt has
# a stale namespace and gets restarted.
# Service names, not container names: heal_vpn_dependents prefixes each one
# with CONTAINER_PREFIX itself, so this list stays readable and stays valid
# whatever a checkout sets.
VPN_DEPENDENT_CONTAINERS := qbittorrent jdownloader2 sabnzbd

heal_vpn_dependents:
	@if [ "$$($(RUNTIME) inspect $(CONTAINER_PREFIX)gluetun --format '{{.State.Running}}' 2>/dev/null)" != "true" ]; then \
		echo "gluetun is not running, nothing to heal."; \
		exit 0; \
	fi; \
	gluetun_started=$$($(RUNTIME) inspect $(CONTAINER_PREFIX)gluetun --format '{{json .State.StartedAt}}' | tr -d '"'); \
	gluetun_epoch=$$(date -d "$$gluetun_started" +%s); \
	stale=""; \
	for c in $(VPN_DEPENDENT_CONTAINERS); do \
		container="$(CONTAINER_PREFIX)$$c"; \
		if [ "$$($(RUNTIME) inspect $$container --format '{{.State.Running}}' 2>/dev/null)" != "true" ]; then \
			continue; \
		fi; \
		c_started=$$($(RUNTIME) inspect $$container --format '{{json .State.StartedAt}}' | tr -d '"'); \
		c_epoch=$$(date -d "$$c_started" +%s); \
		if [ "$$c_epoch" -lt "$$gluetun_epoch" ]; then \
			stale="$$stale $$container"; \
		fi; \
	done; \
	if [ -n "$$stale" ]; then \
		echo "Restarting containers stale relative to gluetun:$$stale"; \
		$(RUNTIME) restart $$stale; \
	else \
		echo "All VPN-namespace-sharing containers are already fresh."; \
	fi

# Rotate API keys and login passwords. Pass SERVICE=<name> to limit the scope,
# e.g. `make rotate_passwords SERVICE=sonarr`. Defaults to all services.
rotate_all:
	@./scripts/rotate-all.sh $(or $(SERVICE),all)

rotate_api_keys:
	@./scripts/rotate-api-keys.sh $(or $(SERVICE),all)

rotate_passwords:
	@./scripts/rotate-passwords.sh $(or $(SERVICE),all)

# Wires qBittorrent/SABnzbd into Sonarr/Radarr/Lidarr/Readarr/Whisparr as
# download clients, and those apps (plus LazyLibrarian/Mylar) into Prowlarr
# as Applications, all through each app's own live API. Idempotent: safe to
# re-run any time, including after a rotation. See docs/CONNECTIONS.md for
# what this covers and what's already wired without it.
wire_connections:
	@./scripts/wire-connections.sh

# Applies .env.tests' profile overrides on top of .env and, if no real VPN
# key is present yet, seeds the local mock WireGuard endpoint so gluetun
# doesn't need one. See docs/VPN_MOCK.md. Never run this against a real
# deployment: it changes which profiles are enabled and, like bootstrap
# itself, is meant for a disposable clone.
enable_test_profiles:
	@./scripts/enable-test-profiles.sh

# Enables every profile with real pytest coverage, bootstraps, and runs the
# full suite: `make bootstrap_tests`. One command for the validation this
# session's own manual walkthrough did by hand before finding three bugs
# that had never been exercised (see docs/VPN_MOCK.md, docs/CONNECTIONS.md).
# Run only against a disposable clone; it rewrites every credential exactly
# like plain bootstrap does.
bootstrap_tests: enable_test_profiles
	@$(MAKE) --no-print-directory bootstrap
	@$(MAKE) --no-print-directory test_extended

# Refuses to start when external storage is configured but not mounted. The
# fstab entry uses nofail so a NAS that is down cannot hold up boot, which
# means the stack can otherwise come up against an empty data/ and the
# downloaders will happily write into the directory underneath the mountpoint.
# See docs/STORAGE.md.
storage_guard:
	@./scripts/storage-mount.sh status >/dev/null 2>&1 || { \
		remote="$$(grep -m1 '^STORAGE_REMOTE=' .env | cut -d= -f2- | tr -d '"')"; \
		if [ -n "$$remote" ]; then \
			echo "ERROR: STORAGE_REMOTE is set ($$remote) but the share is not mounted."; \
			echo "Run 'make storage_mount' first, or clear STORAGE_REMOTE to use local disk."; \
			exit 1; \
		fi; \
	}

start: storage_guard permissions_repair
	@echo "Generating Homepage's services.yaml for the currently enabled profiles..."
	@./scripts/generate-homepage-services.py
	@if [ "$(RUNTIME)" = "podman" ]; then \
		stopping=$$(podman ps -a --format "{{.ID}} {{.State}}" | awk '/stopping/{print $$1}'); \
		if [ -n "$$stopping" ]; then \
			echo "Force-killing containers stuck in stopping state..."; \
			echo "$$stopping" | xargs podman kill 2>/dev/null || true; \
		fi \
	fi
	@echo "Ensuring required networks exist..."
	@./scripts/check-network-subnets.sh
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_apps || $(RUNTIME) network create $(COMPOSE_PROJECT_NAME)_apps
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_services || $(RUNTIME) network create --internal --subnet ${SERVICES_SUBNET} --ip-range ${SERVICES_DYNAMIC_IP_RANGE} $(COMPOSE_PROJECT_NAME)_services
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_media || $(RUNTIME) network create --subnet ${MEDIA_SUBNET} --ip-range ${MEDIA_DYNAMIC_IP_RANGE} $(COMPOSE_PROJECT_NAME)_media
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_observability || $(RUNTIME) network create --internal --subnet ${OBSERVABILITY_SUBNET} $(COMPOSE_PROJECT_NAME)_observability
	@echo "Starting VPN gateway..."
	# vpn_mock has to be up before gluetun, not alongside everything else.
	# When VPN_MOCK_PROFILE is enabled, vpn_mock IS the WireGuard endpoint
	# gluetun dials (docs/VPN_MOCK.md), and gluetun's healthcheck only passes
	# once that tunnel carries traffic. wait_for_gluetun below then blocks on
	# exactly that for 180s, while vpn_mock would only start in the "all
	# containers" pass underneath it. From a fully stopped stack that is a
	# deadlock: confirmed live, gluetun sat in a restart loop logging
	# "dial tcp4: lookup github.com: i/o timeout" until the wait timed out and
	# the whole target failed, and starting vpn_mock by hand made gluetun
	# healthy within 10s with nothing else changed. It went unnoticed because
	# seed-vpn-mock.sh leaves vpn_mock running, so the first bootstrap after
	# seeding works and only a later down/up cycle exposes it.
	@if [ "$(VPN_MOCK_PROFILE)" = "enabled" ]; then \
		echo "Starting the local mock VPN endpoint gluetun dials..."; \
		$(COMPOSE) $(COMPOSE_FILES) --profile enabled up --detach --no-recreate vpn_mock; \
	fi
	@$(COMPOSE) $(COMPOSE_FILES) --profile enabled up --detach --no-recreate gluetun
	$(call wait_for_gluetun)
	@echo "Starting all containers..."
	# Run in the background and judged by what is running, not by whether it
	# returned. podman-compose answers neither question on its own: it returns 0
	# when every container failed to create, and intermittently never returns when
	# they all succeeded. Polling alongside it means a start costs what the stack
	# actually needs rather than the full bound on the hang, and the assert stops
	# early once the process is gone since nothing more will appear then.
	@set -e; \
	$(COMPOSE) $(COMPOSE_FILES) --profile enabled up --detach --no-recreate & \
	up_pid=$$!; \
	trap 'kill $$up_pid 2>/dev/null || true' EXIT; \
	COMPOSE_UP_PID=$$up_pid ./scripts/assert-stack-started.sh $(COMPOSE_FILES)
	@echo "$(VPN_ON)" > $(VPN_STATE_FILE)

start_library: storage_guard permissions_repair
	@echo "Starting Media Library containers..."
	@./scripts/check-network-subnets.sh
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_apps || $(RUNTIME) network create $(COMPOSE_PROJECT_NAME)_apps
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_services || $(RUNTIME) network create --internal --subnet ${SERVICES_SUBNET} --ip-range ${SERVICES_DYNAMIC_IP_RANGE} $(COMPOSE_PROJECT_NAME)_services
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_media || $(RUNTIME) network create --subnet ${MEDIA_SUBNET} --ip-range ${MEDIA_DYNAMIC_IP_RANGE} $(COMPOSE_PROJECT_NAME)_media
	@$(COMPOSE) --file docker-compose.yml --file docker-compose-media-library.yml --profile enabled up --detach --no-recreate

start_observability: storage_guard permissions_repair
	@echo "Starting Observability containers..."
	@./scripts/check-network-subnets.sh
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_apps || $(RUNTIME) network create $(COMPOSE_PROJECT_NAME)_apps
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_services || $(RUNTIME) network create --internal --subnet ${SERVICES_SUBNET} --ip-range ${SERVICES_DYNAMIC_IP_RANGE} $(COMPOSE_PROJECT_NAME)_services
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_observability || $(RUNTIME) network create --internal --subnet ${OBSERVABILITY_SUBNET} $(COMPOSE_PROJECT_NAME)_observability
	@$(COMPOSE) --file docker-compose-observability.yml --profile enabled up --detach

stop: stop_all

stop_all:
	@echo "Stopping containers (if they are running)..."
	@$(COMPOSE) $(STOP_COMPOSE_FILES) --profile enabled stop

update_containers:
	@echo "Stopping containers..."
	@$(COMPOSE) $(STOP_COMPOSE_FILES) --profile enabled stop

	@echo "Ensuring required networks exist..."
	@./scripts/check-network-subnets.sh
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_apps || $(RUNTIME) network create $(COMPOSE_PROJECT_NAME)_apps
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_services || $(RUNTIME) network create --internal --subnet ${SERVICES_SUBNET} --ip-range ${SERVICES_DYNAMIC_IP_RANGE} $(COMPOSE_PROJECT_NAME)_services
	@$(RUNTIME) network exists $(COMPOSE_PROJECT_NAME)_observability || $(RUNTIME) network create --internal --subnet ${OBSERVABILITY_SUBNET} $(COMPOSE_PROJECT_NAME)_observability

	@echo "Pulling images..."
	@$(COMPOSE) $(COMPOSE_FILES) pull

	@echo "Starting containers..."
	@$(COMPOSE) $(COMPOSE_FILES) --profile enabled up --detach

update_pre_commit:
	@echo "Updating pre-commit hooks..."
	@pre-commit autoupdate

tests/.venv:
	@echo "Creating test virtual environment..."
	@python3 -m venv tests/.venv
	@tests/.venv/bin/pip install -q -r tests/requirements.txt
	@echo ".OK!"

# Three passes instead of one invocation: most of this suite's runtime is
# concentrated in a small number of tests that mutate shared, live
# container state (rotation, wiring, killswitch), which cannot be run
# concurrently with each other; everything else is read-only and safe to
# parallelize with pytest-xdist. rotation_isolated is the subset of
# rotation/pw_rotation safe to run in parallel with itself: the
# password-rotation cases only ever touch their own container and their
# own Prowlarr Application row, and the api-key cases' shared homepage
# restart is retried against podman's transient "container state improper"
# error precisely because parallel invocations race on it (see pytest.ini
# and conftest.py's restart_container()). It gets its own parallel pass
# too, separate from the read-only tier since it still needs the live
# stack. rinse_and_repeat is excluded here entirely; see test_extended.
test: tests/.venv ## Run the full test suite (requires the stack to be running)
	@tests/.venv/bin/pytest -n auto -m "not rotation and not pw_rotation and not wiring and not killswitch and not rinse_and_repeat" $(PYTEST_ARGS)
	@tests/.venv/bin/pytest -n 4 --dist loadgroup -m "rotation_isolated" $(PYTEST_ARGS)
	@tests/.venv/bin/pytest -m "(rotation or pw_rotation or wiring or killswitch) and not rotation_isolated" $(PYTEST_ARGS)

# The serial (rotation or pw_rotation or wiring or killswitch) tier test
# excludes above genuinely needs a real app restart to complete and
# report healthy within its own wait budget, over and over, for dozens of
# apps in a row. Confirmed live: that's reliable on a real bench's own
# hardware (two full clean runs, zero failures each), but not on a
# GitHub-hosted runner's shared, more constrained resources, where the
# same restarts intermittently overrun the exact same wait budgets and
# retry counts that are already tuned for exactly this kind of transient
# "container state improper" race (see this file's own comment on
# rotation_isolated above). CI runs this instead of plain test; make
# bootstrap_tests (a real bench, pre-release) still runs the full thing.
#
# wiring_readonly is the exception to that wiring exclusion: it only reads the
# wiring back and runs each app's own Test action, so it neither restarts a
# container nor writes anything, and the module's autouse fixture skips
# re-running wire-connections.sh when that is the whole selection. It does need
# the wiring to already exist, which the CI job's own `make wire_connections`
# step (and, locally, make bootstrap) does. Serial rather than -n auto: it is a
# handful of HTTP calls, so a worker pool costs more to start than it saves.
test_ci: tests/.venv ## Run the fast tiers only (read-only + rotation_isolated + wiring_readonly); what CI runs
	@tests/.venv/bin/pytest -n auto -m "not rotation and not pw_rotation and not wiring and not killswitch and not rinse_and_repeat" $(PYTEST_ARGS)
	@tests/.venv/bin/pytest -n 4 --dist loadgroup -m "rotation_isolated" $(PYTEST_ARGS)
	@tests/.venv/bin/pytest -m "wiring_readonly" $(PYTEST_ARGS)

test_prerequisites: tests/.venv ## Run only pre-flight checks (no containers needed)
	@tests/.venv/bin/pytest -m prerequisites $(PYTEST_ARGS)

test_no_rotate_passwords: tests/.venv ## Run full test suite except password rotation (rotate-passwords.sh)
	@tests/.venv/bin/pytest -m "not pw_rotation" $(PYTEST_ARGS)

# rinse_and_repeat (stop/start and down/start cycles against the whole
# stack) is the single most expensive marker by far and, unlike
# rotation/wiring/killswitch, isn't testing a specific credential or
# connection: it's a lifecycle-stability check best run deliberately
# (before a release, after touching bootstrap/compose) rather than on
# every `make test`. `bootstrap_tests` calls this, not plain `test`.
test_extended: test ## Run the full suite plus rinse-and-repeat lifecycle cycles
	@tests/.venv/bin/pytest -m "rinse_and_repeat" $(PYTEST_ARGS)
