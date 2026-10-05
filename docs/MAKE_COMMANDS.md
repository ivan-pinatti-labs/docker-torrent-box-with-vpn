# Make commands

Quick reference for every user-facing `make` target. Grouped by what you'd
reach for it to do, not alphabetically. Targets not listed here
(`.env`, `certs/cert.conf`, `configs/flaresolverr/config/chromedriver`)
are internal file-based prerequisites, and the `suite_*` targets are the test
tiers the nested test runner calls from the inside; none are commands you run
directly.

## First-time setup

| Target | What it does |
| --- | --- |
| `make bootstrap` | The one command for first-time setup: seeds every app's config from its `.example` templates, remaps directory ownership, generates the self-signed certificate, builds the two locally built images (LazyLibrarian, Mylar), starts the stack, waits for Gluetun to connect, wires app-to-app connections, then rotates every seeded credential. Meant to run once. See [README §2](../README.md#2-run-make-bootstrap). |
| `make check_requirements` | Prints the versions of every required tool (make, podman/docker, compose, yq, xmlstarlet, kernel, WireGuard module) so you can confirm your host is ready before bootstrapping. |
| `make install_requirements` | Prints OS-specific install commands for the required tools. Informational only, doesn't install anything itself. |
| `make generate_certificate` | (Re)generates the self-signed TLS certificate and pushes the new password into every app's config. `bootstrap` calls this automatically if no certificate exists yet. |
| `make rotate_certificate` | Regenerates the certificate on an already-running stack (wraps `scripts/rotate-certificate.sh`). |
| `make configure_jellyfin_network` | Sets Jellyfin's `BaseUrl`/`KnownProxies` in `network.xml`, seeded correctly by default so this is normally a no-op; only needed to correct drift after changing `JELLYFIN_BASE_URL`/`NGINX_MEDIA_IP`. `bootstrap` calls it automatically as a safety net. |
| `make configure_jdownloader2_api` | Opens jDownloader2's REST API and older `/jd` namespace to the services network so Mylar can reach them, editing `RemoteAPIConfig.json` after jDownloader2's own first boot. `bootstrap` calls it automatically; see [JDOWNLOADER2.md](JDOWNLOADER2.md). |

## Starting, stopping, restarting

| Target | What it does |
| --- | --- |
| `make start` | Starts the full stack: creates required networks, starts Gluetun and waits for it to be healthy, then starts everything else. |
| `make start_library` | Starts only the Media Library containers (`docker-compose-media-library.yml`). |
| `make start_observability` | Starts only the observability stack (Prometheus, Loki, Grafana, Alloy, exporters). |
| `make stop` / `make stop_all` | Stops all containers without removing them. |
| `make down` | Stops **and removes** all containers (state on disk is untouched). |
| `make restart` | Restarts Gluetun first and waits for it to be healthy, then restarts everything else, avoiding a race where VPN-namespace-sharing containers (qBittorrent, SABnzbd, JDownloader2) restart concurrently with Gluetun and get left attached to its old, torn-down network namespace. |
| `make heal_vpn_dependents` | Detects and restarts any container still attached to Gluetun's *previous* network namespace after Gluetun restarted on its own (its `restart: unless-stopped` policy, or a lost WireGuard handshake) outside of `make restart`. |
| `make update_containers` | Stops the stack, pulls fresh images, and starts it back up. |
| `make pull_docker_images` | Pulls every enabled image without stopping or restarting anything. |
| `make build_images` | Builds the two custom images this stack maintains itself (LazyLibrarian, Mylar). `bootstrap` calls this automatically; run it by hand to rebuild after bumping `LAZYLIBRARIAN_VERSION`/`MYLAR_VERSION`. |

## Credentials and wiring

| Target | What it does |
| --- | --- |
| `make rotate_all` | Rotates both API keys and passwords for every enabled app. Pass `SERVICE=<name>` to scope it to one app, e.g. `make rotate_all SERVICE=sonarr`. See [docs/ROTATION.md](ROTATION.md). |
| `make rotate_api_keys` | Rotates API keys only. Same `SERVICE=` scoping. |
| `make rotate_passwords` | Rotates login passwords only. Same `SERVICE=` scoping. |
| `make wire_connections` | Wires qBittorrent/SABnzbd into the \*arr apps as download clients, and those apps into Prowlarr as Applications, all through each app's own live API. Idempotent, safe to re-run any time, including after a rotation or after enabling a previously-disabled app. See [docs/CONNECTIONS.md](CONNECTIONS.md). |

## Permissions

See [docs/PERMISSIONS.md](PERMISSIONS.md) for the ownership model these implement.

| Target | What it does |
| --- | --- |
| `make permissions_check` | Reports whether on-disk ownership matches `permissions.yml` without changing anything. |
| `make permissions_repair` | Applies `permissions.yml`, recursively. `make start`/`start_library`/`start_observability` all depend on this, so it runs automatically before those. |
| `make permissions_smoke` | Verifies containers can actually read/write the paths they need. |
| `make permissions_host_smoke` | Verifies the host operator (you) can create/edit/move/delete files under manifest-managed directories without `sudo`. |

## Backup and restore

| Target | What it does |
| --- | --- |
| `make backup` / `make backup-configs` | Lean backup: `.env`, `certs`, and `configs`, with logs/caches/large regenerable files excluded. |
| `make backup-full` | Same scope as above but with far fewer exclusions, closer to a full snapshot. |
| `make backup-schedule` | Installs a cron entry that runs `make backup` on a schedule (prompts for frequency/time in a real terminal, defaults to daily at 03:00 otherwise). See [docs/BACKUP.md](BACKUP.md#scheduling). |
| `make restore-configs BACKUP=<path>` | Restores from a backup archive. Takes its own safety backup of the current state first. `BACKUP=` is required. |
| `make restore-full` | Alias of `restore-configs`. |

## Testing

See [docs/CONTRIBUTING.md](CONTRIBUTING.md) for how these fit into CI.

Every test target except `make coverage` runs in the nested test runner: the
committed tree is streamed into a throwaway container of the podman-nested
image, which stands up its own stack in its own storage and runs pytest there,
so nothing touches a stack or a deployment on this machine and nothing runs on
the host's Python. The host needs Podman and nothing else. See
[docs/TESTING.md](TESTING.md#where-the-suite-runs).

| Target | What it does |
| --- | --- |
| `make test` | Stands a fresh stack up with the test profiles and runs the full suite in three passes (parallel read-only tests, a parallel-safe rotation subset, then the remaining mutating tests serially). Does **not** include `rinse_and_repeat`. |
| `make test_extended` | `make test` plus the `rinse_and_repeat` lifecycle tests (stop/start and down/start cycles), the slowest tier, run deliberately rather than on every `make test`. |
| `make test_nested` | The first two passes of `make test` plus the read-only wiring checks, no serial rotation/wiring/killswitch tier. What CI's own integration job runs; not a substitute for `make test` or `make bootstrap_tests` outside CI. |
| `make test_prerequisites` | Pre-flight and repository checks only, in the runner, with no stack. What the `Prerequisite Checks` job runs. The host side of the pre-flight is `make check_requirements` above. |
| `make test_no_rotate_passwords` | The full suite except `rotate-passwords.sh` coverage. |
| `make test_marker MARKER=<expression>` | One pytest marker expression in a single pass, against a fresh stack, for example `MARKER=security`. |
| `make coverage` | The container free unit tier (`tests/unit`) under coverage.py and kcov, in podman containers; fails unless every Python file in `scripts/` and every shell script the repository writes (found, not listed: `make print-shell-scripts`) is at 100%. Needs no stack. See [docs/TESTING.md](TESTING.md#the-unit-tier). |
| `make bootstrap_tests` | Enables every profile with real test coverage, runs `bootstrap` from scratch, then the `test_extended` tiers, all in the runner. This is the release-validation command. |

`PYTEST_ARGS="..."` appends extra arguments to whichever pytest invocations
a target runs. Note `make test`/`test_extended` are multiple separate pytest
calls, each with its own `-m` marker filter, and pytest's `-m` is
single-value: passing `PYTEST_ARGS="-m security"` to those targets
overrides each pass's own filter rather than combining with it. Use
`make test_marker MARKER=security` when you want just one marker.

The runner's own knobs (`NESTED_MEMORY`, `NESTED_LABEL`, `NESTED_STORAGE`,
`SUITE_DISABLE_PROFILES` and the rest) are described in the Makefile, above
the test targets.

## Maintenance

| Target | What it does |
| --- | --- |
| `make disk_status` | Prints a disk usage report. |
| `make storage_mount` | Mounts the external storage share at `DATA_FOLDER`. Refuses if the mountpoint is not empty, so a failed mount cannot leave the apps writing underneath it. |
| `make storage_unmount` | Unmounts the share. Refuses while stack containers are running. |
| `make storage_status` | Reports the share, mountpoint, live mount options, free space and whether the boot entry is installed. Exits non-zero when configured but not mounted. |
| `make storage_install_boot` | Adds the `/etc/fstab` entry so the share returns after a reboot. Prints the exact line, requires typing `yes`, and backs up `/etc/fstab` first. |
| `make storage_uninstall_boot` | Removes that entry, backing up `/etc/fstab` first. |
| `make korsync_users ARGS="..."` | Manages KorSync users; see `scripts/korsync-users.sh` for accepted arguments. |
| `make prune_cache` | Prunes the nginx reverse-proxy cache. |
| `make rotate_nginx_logs` | Rotates nginx logs. |
| `make clean` | Stops the stack, `git clean -fdx`s the working tree, and wipes the `certs` and `shared` folders. Destructive. |
| `make clean_all` | Everything `clean` does, plus wipes the `media` folder (keeps `metadata.db`). More destructive. |

## Development / CI

| Target | What it does |
| --- | --- |
| `make pre_commit` | Runs all pre-commit hooks against the whole repo. |
| `make sanity_fast` | The normal local validation path: same as `pre_commit`. |
| `make sanity_full` | `sanity_fast` plus the pre-push pass: full-history secret scan, checkov, trivy, link check. |
| `make update_pre_commit` | Runs `pre-commit autoupdate`. |
| `make detect_secrets_create_baseline` | Regenerates `.secrets.baseline` for the detect-secrets hook. |
