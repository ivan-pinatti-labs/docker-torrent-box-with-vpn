# Credential and Certificate Rotation

The stack ships with pre-configured API keys and passwords. `make bootstrap`
already rotates all of them once, as its last step (after starting the stack
and wiring app-to-app connections, see [docs/CONNECTIONS.md](CONNECTIONS.md),
since some rotations, qBittorrent's in particular, read the current
credential out of a DownloadClients entry that only exists once wiring has
run). Everything below is for rotating again later: on a recurring schedule,
after enabling a service that was disabled during bootstrap, or before
exposing anything beyond your own machine if the initial rotation was
skipped. The scripts below rotate a credential in the app that owns it and
then sync the new value into every consumer, so the integrations keep
working.

## Quick Reference

| What                    | Make target               | Script                          |
| ----------------------- | ------------------------- | ------------------------------- |
| API keys and passwords  | `make rotate_all`         | `scripts/rotate-all.sh`         |
| API keys only           | `make rotate_api_keys`    | `scripts/rotate-api-keys.sh`    |
| Login passwords only    | `make rotate_passwords`   | `scripts/rotate-passwords.sh`   |
| Self-signed certificate | `make rotate_certificate` | `scripts/rotate-certificate.sh` |
| Nginx host logs         | `make rotate_nginx_logs`  | `scripts/rotate-nginx-logs.sh`  |

All rotation targets accept `SERVICE=<name>` to limit the scope:

```shell
make rotate_all                     # everything
make rotate_all SERVICE=sonarr      # one service, keys and password
make rotate_api_keys SERVICE=radarr
make rotate_passwords SERVICE=qbittorrent
```

API key rotation requires the stack already running, because it goes through
each app's own API (via `podman exec` into the app container). Certificate
and log rotation work on files only.

Generated password length and character set are configurable in `.env`:
`ROTATE_PASSWORD_LENGTH` (default `16`, minimum `8`) and
`ROTATE_PASSWORD_SPECIAL_CHARS` (default `false`). Setting the latter to
`true` adds a deliberately narrow symbol subset (`! @ ^ * ( ) _ ~ -`): the
password gets embedded raw, with no escaping, into `sed` replacement text,
`curl` form-urlencoded bodies, and single-quoted Python string literals
across the rotate functions, so the set excludes anything with special
meaning in any of those contexts (quotes, backslash, `$`, backtick, `|`,
`&`, `=`, `%`, `+`, `#`, `;`). See the comment above `gen_password()` in
`scripts/rotate-passwords.sh` for the full reasoning.

Password rotation respects the compose profile flags in `.env`: with the
`all` target, services whose `<SERVICE>_PROFILE` is `disabled` are skipped
with a note, and requesting a disabled service explicitly (`SERVICE=<name>`)
is an error. Most password rotations stop, edit, and start their own
container regardless of its prior state; those stop calls are batched, so
stopping several containers for one rotation (e.g. qBittorrent's or
SABnzbd's Servarr consumers) waits for the slowest one instead of each in
turn. The few rotations that log into the app's own live API instead
(Servarr apps, qBittorrent, Grafana, Jellyfin) need their container already
running; before dispatch, the script starts every one of these containers
that this run will need in a single batched call and waits for all of them
to report healthy together, rather than starting and waiting on each in
turn as its rotation happens to come up. If a container never comes up,
that service is skipped in `all` mode or the run exits with an error for an
explicit target. `make start` returns as soon as it has issued `podman
start` for everything, without waiting for each app's own healthcheck, so
running `make rotate_passwords` right after `make start` will often catch
some of these containers still warming up; the script distinguishes that
("Waiting for already-running containers to become healthy") from actually
stopped ("Starting stopped containers needed for rotation") so the message
doesn't claim to be starting something that's already up.

With the `all` target, the eight services with no shared container or
config file (Audiobookshelf, Bazarr, Calibre-Web, Grafana, jDownloader2,
Jellyfin, NZBHydra2, Prowlarr) rotate concurrently in the background, with
each one's output streamed live prefixed by `[service]` (interleaved,
since they genuinely run at the same time) rather than buffered and
printed only after the whole group finishes. The rest run sequentially
exactly as a single-target invocation would.
Calibre, LazyLibrarian, Mylar, qBittorrent, SABnzbd, and the remaining
Servarr apps stay sequential because they touch the same containers,
`config.ini` files, or DB tables as one another (qBittorrent's and
SABnzbd's rotations stop the very Servarr containers their own password
rotation needs running, for instance); running those concurrently would
race on the same file or database writes. See the "Editing runtime app
state" note in `AGENTS.md` for why that's unsafe.

## API Keys (`rotate-api-keys.sh`)

Valid targets: `sonarr`, `radarr`, `lidarr`, `readarr`, `whisparr`,
`prowlarr`, `bazarr`, `lazylibrarian`, `mylar`, `nzbhydra2`, `jellyfin`,
`all`.

For each Servarr app the script writes a new `ApiKey` into the app's
`config.xml` (the apps ignore key changes sent over their API), then updates
every consumer of that key:

- The matching application entry in Prowlarr (over the Prowlarr API).
- Bazarr's `sonarr.apikey` and `radarr.apikey` in
  `configs/bazarr/config/config/config.yaml`.
- Recyclarr's `sonarr_apikey` and `radarr_apikey` in
  `configs/recyclarr/config/secrets.yml`.
- The app's own `configs/<app>/secrets/api_key.txt`, a compose secret
  homepage reads directly (see `docs/COMPOSE_CONVENTIONS.md`); homepage is
  restarted, not recreated, to pick it up.

The non-Servarr targets:

- **LazyLibrarian** and **Mylar** keep their key in `config.ini` and persist
  their in-memory config on shutdown, so the script stops the container,
  edits the file, and starts it again. Their Prowlarr application entries
  (and Homepage for Mylar) are updated too.
- **NZBHydra2** gets a new `main.apiKey` in `nzbhydra.yml` (written in plain
  text; NZBHydra re-obfuscates it on its next save). Consumers updated: the
  `Indexers` tables of all five Servarr databases, LazyLibrarian's Newznab
  and Torznab entries, and Mylar's `extra_newznabs`/`extra_torznabs` lines.
- **Jellyfin** keys cannot be chosen, so the script creates a new key over
  the Jellyfin API, writes it to `configs/jellyfin/secrets/api_key.txt`
  (the only record of Jellyfin's current key; there is no config.xml
  equivalent), and revokes the old one. This requires an admin account,
  which `scripts/wire-connections.sh`'s `ensure_jellyfin_setup()` *attempts*
  to create through Jellyfin's own first-run Startup API (username and
  password both `jellyfin`) as part of `make wire_connections`/
  `make bootstrap`, but that attempt is unreliable (see
  [docs/CONNECTIONS.md](CONNECTIONS.md)) and often doesn't succeed. When it
  hasn't, rotation skips Jellyfin with a note instead of failing; visit
  `http://localhost:${JELLYFIN_HTTP_PORT}/` once in a browser to complete
  the wizard reliably, then `make rotate_all SERVICE=jellyfin` picks it up.

Apps whose key was rewritten on disk are restarted or recreated
automatically so they load the new key, and Homepage is restarted (it reads
every key here from a mounted secret file, not `env_file`, so a restart is
enough). This homepage restart happens unconditionally at the end of every
`rotate-api-keys.sh` invocation, including single-app targets, so if you
script multiple rotations to run concurrently they can race on it: podman
refuses a restart while another one triggered it is still mid-transition
("container state improper"). The restart is retried against exactly that
error rather than treated as fatal (see `retry()` in the script); a normal,
one-at-a-time `rotate_all`/`rotate_api_keys` invocation never hits this. The
summary table masks the keys (`first4****`); the actual values live in the
respective config files.

## Passwords (`rotate-passwords.sh`)

Valid targets (alphabetical): `audiobookshelf`, `bazarr`, `calibre`,
`calibre-web`, `grafana`, `jdownloader2`, `jellyfin`, `lazylibrarian`,
`lidarr`, `mylar`, `nzbhydra2`, `prowlarr`, `qbittorrent`, `radarr`,
`readarr`, `sabnzbd`, `sonarr`, `whisparr`, `all`.

The summary table prints service, user, and new password, and the rotation
functions, execution order, summary rows, and validation checks are all
alphabetical by service.

- **Audiobookshelf**: writes a new bcrypt hash for the `root` user directly
  to the `users` table in `absdatabase.sqlite` (no rotation API exists
  without the current password). Homepage talks to Audiobookshelf with a
  JWT API token, not the password, so no consumer update is needed. That
  row is created automatically by `ensure_audiobookshelf_setup()` (via
  Audiobookshelf's own `/init` endpoint, username `root`) as part of
  `make wire_connections`/`make bootstrap`. If it genuinely doesn't exist
  yet, rotation still skips with a note rather than failing.
- **Bazarr**: writes the MD5 hash of the new password to `config.yaml`
  (Bazarr stores MD5 by design).
- **Calibre**: rotates two independent logins that share one password here
  for simplicity: the content server (users in `server-users.sqlite`,
  plain text, read at startup) and the desktop GUI/noVNC session (basic
  auth via the shared secret file `configs/calibre/secrets/password.txt`,
  read via `FILE__PASSWORD` and re-read on every start, so a restart
  suffices). Also updates LazyLibrarian's `calibre_pass` in its
  `config.ini`. The content server's `users` table (and the row for its
  user, username `calibre`) is created automatically by
  `ensure_calibre_content_server_user()` (a non-interactive
  `calibre-server --manage-users` call) as part of `make wire_connections`/
  `make bootstrap`. If it genuinely doesn't exist yet, that half of the
  rotation still skips with a note; the GUI/noVNC login and LazyLibrarian's
  copy rotate normally either way. The content server only starts once the
  desktop GUI is up, and the GUI reliably wedges on its single instance
  lock after a stop/start or recreate cycle; validation gives it a normal
  boot window, then self-heals once by running `podman exec calibre s6-svc
  -r /run/service/svc-de` before giving it a second window, so an operator
  does not need to notice and run that command by hand. Validating the
  desktop GUI login is what actually confirms the password rotated
  correctly; the content server's own AJAX API
  (`CALIBRE_GUI_WEB_HTTP_PORT`, default 8081) is checked separately and
  only informationally, since it defaults to the same port as Selkies'
  desktop-streaming data websocket inside the `lscr.io/linuxserver/calibre`
  image itself: a pre-existing collision unrelated to credential rotation,
  not something this script can work around.
- **Calibre-Web**: writes a new password hash for the `admin` user (the
  image's own hardcoded default, not this project's usual per-app
  placeholder) directly to `app.db` (no API exists) and updates the shared
  secret file `configs/calibre-web/secrets/password.txt`, which Homepage
  reads directly. `ensure_calibre_web_setup()` sets `config_calibre_dir` to
  this stack's shared Calibre library automatically as part of
  `make wire_connections`/`make bootstrap`, so the container isn't stuck
  redirecting every request to its own `/admin/dbconfig` setup page.
  It deliberately does **not** configure Calibre-Web's own HTTPS or rename
  its default user: doing either was tried, and reproducibly wiped the
  entire `user` table (including the built-in "Guest" row) on the next
  container start in live testing, for a reason not identified in the time
  available. Calibre-Web is therefore only ever reachable here over plain
  HTTP (`CALIBRE_WEB_CONTAINER_HTTP_PORT`, or through nginx's own HTTPS
  termination); it also reinstalls its Calibre mod on every restart, so
  validation gives it a normal boot window, then one restart-and-retry,
  mirroring Calibre's own handling of the same slow-restart image.
  Separately, the `admin` row has been observed to disappear from
  Calibre-Web's own user table sometime after its first real library is
  configured and the app runs a while, organically, unrelated to any
  write this stack makes, and not yet root-caused. Rotation checks the
  actual row count rather than trusting a successful `UPDATE` with no
  matching rows, and skips with a note (rather than silently claiming
  success) if the user is gone when it runs.
- **Grafana**: changes the admin password over Grafana's API, then keeps
  `grafana.ini` and the shared secret file
  `configs/grafana/secrets/homepage_auth.txt` (the precomputed Basic-auth
  header, not the raw password) in sync.
- **jDownloader2**: writes the new password to the secret file
  `configs/jdownloader2/secrets/password.txt`. This image's own
  Docker-secrets support (`CONT_ENV_<VAR>`) does not work: its Dockerfile
  pre-declares `WEB_AUTHENTICATION_USERNAME`/`PASSWORD` as empty-string env
  vars, and `/init`'s secrets loader used to set a variable only if it was
  currently *unset*, so it always found them already "set" (to `""`) and
  silently skipped loading the secret. This repository carried
  `patches/jdownloader2/10-webauth.sh` over the image's own cont-init.d
  script until 2026-09-02 to bypass that.

  `baseimage-gui` 4.13.0 fixed it: `load_env_var()` takes a `force` argument
  and the secret loader passes it, so a secret now overrides an empty image
  default. The pinned image is built on 4.13.1, verified by extracting
  `/init` from it, so the patch is gone and the image's own loader is what
  reads the secret. It still runs on every container start, so a plain
  restart picks up a rotated password. No other consumer holds this
  credential. See issue #107.
- **Jellyfin**: sets a new password for the `jellyfin` user over Jellyfin's
  API, authenticated with the admin API key read from
  `configs/jellyfin/secrets/api_key.txt`. That key is unaffected by a
  password rotation, so no consumer update is needed. Same unreliable
  account-creation attempt and skip-with-a-note fallback as API key
  rotation above.
- **LazyLibrarian** and **Mylar**: WebUI passwords in their `config.ini`.
- **NZBHydra2**: writes a new bcrypt hash to `nzbhydra.yml`.
- **qBittorrent**: logs into the WebUI API with the current password (read
  from Sonarr's download client settings), sets the new one, then updates
  every consumer: the `DownloadClients` tables of all five Servarr apps,
  LazyLibrarian's and Mylar's download client settings, and the shared
  secret file `configs/qbittorrent/secrets/password.txt`, which
  qbittorrent_exporter and Homepage both read directly.
- **SABnzbd**: rotates the password, API key, and NZB key together. Updates
  `configs/sabnzbd/config/sabnzbd.ini`, `configs/sabnzbd/.env.secrets`
  (password and NZB key only), the shared secret file
  `configs/sabnzbd/secrets/api_key.txt` (read directly by sabnzbd_exporter
  and Homepage), the Servarr `DownloadClients` tables, LazyLibrarian, Mylar,
  and Notifiarr.
- **Servarr apps** (Lidarr, Prowlarr, Radarr, Readarr, Sonarr, Whisparr):
  the new login password is set through each app's host config API, which
  hashes it internally.

Every file or database edit follows the stop, edit, start pattern: apps read
their config only at startup and persist in-memory state on shutdown, which
would clobber a live edit. Only changes made through an app's own API happen
while it runs. Both scripts end with a validation phase that proves each
rotated credential is accepted by its service (login or API probe, with
retries while containers come back up) and exit nonzero if any check fails.
Unlike rotation, validation is read-only (a login attempt against each
service's own container, nothing shared), so every rotated service is
checked concurrently regardless of target, not just the services rotation
itself can safely parallelize; results print in whichever order each check
finishes, not a fixed order.

The summary table prints the new passwords **in full**: the apps store only
hashes, so the table is the single opportunity to record them. Save them in
your password manager immediately. Some apps cache credentials in memory;
run `make restart` if a login fails after rotation.

## Combined (`rotate-all.sh`)

Runs the API key rotation followed by the password rotation for the same
target. Defaults to `all` when no target is given. This is what
`make rotate_all` calls.

## Certificate (`rotate-certificate.sh`)

Regenerates `certs/server.key`, `certs/server.crt`, and `certs/server.pfx`
with a new random PKCS#12 password, then syncs that password into every
consumer:

- `SslCertPassword` in the `config.xml` of Lidarr, Prowlarr, Radarr, Readarr,
  Sonarr, and Whisparr (apps with SSL disabled are skipped).
- `CertificatePassword` in Jellyfin's `network.xml`.
- `sslKeyStorePassword` in NZBHydra2's `nzbhydra.yml`.

The new password is stored in `certs/cert.conf`, which is gitignored. File
permissions are normalized to `644` after generation: the certificate files
are read by many services running as distinct non-root container UIDs under
rootless Podman, so they must stay world-readable. The script prints the
recreate command for the affected containers at the end; run it for the new
certificate to take effect.

Subject and SAN fields come from `certs/cert.conf` and `.env`
(`JELLYFIN_PROXY_DOMAIN`, `LAN_IP`, `GLUETUN_SERVICES_IP`,
`GLUETUN_OBSERVABILITY_IP`). For the initial certificate use
`make generate_certificate` instead; the rotate script is for replacing an
existing one.

## Nginx Logs (`rotate-nginx-logs.sh`)

Copies each `*.log` under the nginx log directory to a timestamped file and
truncates the original, then compresses rotated files older than
`LOG_RETENTION_DAYS` and deletes archives older than
`LOG_ARCHIVE_RETENTION_DAYS`. Runs daily via the log rotator container
(`LOG_ROTATION_CRON`); see [Growth Controls](GROWTH_CONTROLS.md).

## Out of Scope

- **Audiobookshelf's token** used by Homepage is a per-user JWT that must be
  rotated manually in the Audiobookshelf UI; see
  [DEPENDENCIES.md](DEPENDENCIES.md).
- **Jackett** is legacy and not covered by any rotation script.
- **Gluetun's WireGuard private key** lives in `configs/gluetun/.secret`;
  rotate it by generating a new config with your VPN provider.

---

See also: [README.md](../README.md), [docs/MAKE_COMMANDS.md](MAKE_COMMANDS.md)
