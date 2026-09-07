# App-to-App Connections

Most of this stack's config is seeded from `.example` templates at bootstrap,
so apps that read their connection settings from a flat config file already
know about each other on first boot. A handful of connections don't work that
way: they live in an app's own SQLite database, populated only through its
live API, which means nothing can pre-seed them the way a template does. This
document covers what those connections are, how they get created, and what's
already wired without any of this. It also covers the related first-run
setup this script completes for four apps that otherwise ship with no
usable account at all until a human clicks through their own web UI once.

## Quick Reference

| What | Make target | Script |
| ---------------------------------- | ---------------------- | ------------------------------ |
| Download clients, Prowlarr apps, Jellyfin library updates | `make wire_connections` | `scripts/wire-connections.sh` |

`make bootstrap` runs this automatically, after the stack's first
`make start` and before it rotates every seeded credential
(`make rotate_all`); wiring has to come first, since some rotations (
qBittorrent's in particular) read the current credential out of a
DownloadClients entry that only exists once wiring has run. Run it again by
hand any time: after enabling an app that was previously disabled, or just to
confirm everything is still wired. Every step checks for an existing entry
first, so re-running is always safe.

## What gets wired

### Download clients (Sonarr, Radarr, Lidarr, Readarr, Whisparr, Prowlarr → qBittorrent, SABnzbd)

Each of these apps keeps its download clients in a `DownloadClients` SQLite
table, created through `POST /api/<version>/downloadclient`. The script:

- Waits (up to 3 minutes) for the app to answer its own `/system/status`,
  since this only makes sense against a running app, and `make start` doesn't
  wait for individual apps to finish warming up.
- Sets up the app's initial WebUI login (username = password = the app's own
  name, matching the README's login table) and relaxes
  `CertificateValidation` to `DisabledForLocalAddresses`, if neither has been
  done yet. Both are required before the app will accept a download client
  pointed at this stack's self-signed cert: `AuthenticationMethod=Forms`
  makes the app reject any `config/host` update, including one that only
  touches certificate validation, unless a WebUI login already exists.
- Fetches the app's own `/downloadclient/schema` for the QBittorrent and
  Sabnzbd implementations, which already carries every field at a sensible
  default, and only overrides what's actually connection-specific: host,
  port, credentials, and category. The category is always set explicitly
  rather than trusted from the schema default: qBittorrent's own
  `categories.json` uses each app's bare name (`radarr`, `sonarr`, ...), but
  e.g. Sonarr's own qBittorrent schema defaults to `tv-sonarr` instead of
  `sonarr`: qBittorrent doesn't validate the category on creation, it just
  silently creates an empty one, which would silently break the
  pre-configured save-path layout. SABnzbd's categories are genre-based
  (`tv`, `movies`, `music`, `ebooks`, `mature`) and validates strictly, so an
  unmatched category fails the request outright rather than creating one.
- Posts the client with `enable = true`.

Prowlarr gets both clients too, through the same `ensure_qbittorrent_client`/
`ensure_sabnzbd_client` helpers (Prowlarr shares the identical DownloadClients
schema shape with every other Servarr app); this is what puts a working
"Download" button on Prowlarr's own Interactive Search results, independent
of anything the arr apps do with their own clients. The category is set to
the bare string `prowlarr`, matching the same convention as the arr apps,
though Prowlarr itself doesn't use it for anything (it isn't sorting content
into genre folders the way Sonarr/Radarr/etc. are).

**Known limitation:** Readarr's own qBittorrent client creation fails every
time, against every qBittorrent version this stack has pinned since #83.
Readarr's retired upstream (see README's Known Issues) never picked up a fix
for qBittorrent 5.2 and later returning `204 No Content` on a successful
login instead of the older `200 OK` with body `Ok.`; Readarr's own client
code still checks for that exact string, so it treats a real, successful
login as a failure and raises an authentication error on every attempt. This
is not a race or a lockout, and re-running `make wire_connections` does not
help; see the comment above `ensure_qbittorrent_client` in
`scripts/wire-connections.sh` for how this was confirmed directly against
Readarr's own source. Readarr's SABnzbd client is unaffected and gets wired
normally.

### Jellyfin library updates (Sonarr, Radarr, Lidarr, Whisparr → Jellyfin)

Each app gets a Connection of type `MediaBrowser`, which is the \*arr name for
Emby/Jellyfin, created via `POST /api/vN/notification` and named
`Emby / Jellyfin`. `updateLibrary` is on, so Jellyfin is told to rescan as soon
as an import, upgrade or rename changes the library. Without it Jellyfin only
notices on its own scheduled scan, and a finished download can sit there
invisible for hours.

**Readarr is not wired**, because it offers no `MediaBrowser` implementation at
all: Jellyfin does not take a book library from it, and Readarr's equivalents
there are Kavita and Subsonic. The script asks each app what it supports rather
than carrying a hardcoded list, and skips the ones that do not, so this stays
correct if upstream changes.

The triggers come from the app's own schema for the same reason. The apps
disagree on them: Sonarr and Radarr have `onDownload`, Lidarr has no such
trigger and uses `onReleaseImport`, and newer versions add `onImportComplete`.
Whichever of those an app advertises is enabled, along with `onUpgrade` and
`onRename`.

The address needs more care than the other connections here. Jellyfin is on the
`media` network while the \*arr apps are on `apps`/`services`, so there is no
container-to-container route and the connection has to reach the port Jellyfin
publishes on the host. Which address gets there from inside a container depends
on the host, so the script probes from the app's own container and uses the
first that answers Jellyfin's `/System/Info/Public`:

1. `LAN_IP` from `.env`, which is what a hand-configured install ends up using
2. `host.containers.internal`, podman's own alias for the host, which is what
   works when `LAN_IP` is still the `.env.example` placeholder
3. `host.docker.internal`, for `RUNTIME=docker`

If none of them answer, the app is skipped with a warning rather than left with
a connection that cannot work.

To check it by hand, open the app, go to Settings > Connect, click
`Emby / Jellyfin` and press **Test**; it should report success. That is the
same call `tests/test_wire_connections.py` makes.

### Readarr → Metadata Provider Source

Readarr's own upstream metadata hub went offline when the project was
retired (see [README's Known Issues](../README.md#known-issues-and-future-improvements)).
`wire_arr_app`'s Readarr branch sets `Settings > Development > Metadata
Provider Source` to the community-run rreading-glasses mirror
(`https://api.bookinfo.pro`) via `GET`/`PUT /api/v1/config/development/{id}`.
It checks the current value first and skips if already set, so re-running
is safe. Not yet confirmed against a live Readarr instance; verify on the
next bench run.

### Prowlarr → Indexer Proxy (FlareSolverr)

If both Prowlarr and FlareSolverr are enabled, the script registers
FlareSolverr as an Indexer Proxy via `POST /api/v1/indexerproxy`, using the
same fetch-schema-then-fill-in-the-host pattern as everything else here.
This only makes the proxy available to choose from; Prowlarr does not
automatically apply it to any indexer. Assign it per indexer that actually
needs a Cloudflare bypass, under Settings > Indexers > (the indexer) >
Proxy in Prowlarr's UI.

### Prowlarr → Applications (Sonarr, Radarr, Lidarr, Readarr, Whisparr, LazyLibrarian, Mylar)

If Prowlarr is enabled (`PROWLARR_PROFILE`), the script registers each of
those apps as an Application via `POST /api/v1/applications`, so Prowlarr can
push indexer sync to them (`syncLevel: fullSync`). Skipped entirely, with a
note, if Prowlarr's container doesn't exist (the same no-op behavior
`scripts/rotate-api-keys.sh`'s `update_prowlarr_application()` already has
for a missing entry).

After registering the applications, the script triggers Prowlarr's
`ApplicationIndexerSync` command and then verifies, through each arr app's
own `GET .../indexer`, that an indexer actually arrived. That verification
step exists because the sync can fail silently: Prowlarr answers an app's
capability probe with 429 while an indexer is in its failure backoff, the
app rejects the pushed indexer with 400, and nothing retries.

**Mylar legitimately ends up with no Prowlarr indexer on a default install,
and that is not a failure.** Prowlarr only pushes an indexer to Mylar when
that indexer advertises category 7030 (Books/Comics), and this stack's
default indexer, Internet Archive, advertises 7000 (Books) but no comics
subcategory. Prowlarr skips it silently: its trace log shows Prowlarr
querying Mylar's `cmd=listProviders` successfully (HTTP 200) and then
logging nothing further for Mylar, while every other application is
processed. LazyLibrarian, which matches on Books, does receive the indexer.
Add any indexer carrying 7030 in Prowlarr and Mylar starts receiving it, no
re-wiring needed.

**Whisparr legitimately ends up with no Prowlarr indexer on a default
install, for the same reason.** Its Application entry only syncs indexers
matching its `syncCategories` (the 6000-series, adult content only), and
Internet Archive's own advertised categories (confirmed live via its
`capabilities.categories`) don't include any of the 6000s. Registration
still succeeds and is the real success signal; `sync_prowlarr_indexers()`
excludes Whisparr from its post-sync indexer-count check for exactly this
reason, and `tests/test_wire_connections.py`'s
`test_prowlarr_indexers_propagated_to_arr_app` skips it too. Add any
indexer carrying a 6000-series category and Whisparr starts receiving it,
no re-wiring needed.

Both Mylar and LazyLibrarian ship a `config.ini.example` that deliberately
defines **no** Prowlarr Torznab entries. Prowlarr populates those itself,
and hand-written placeholder entries actively break it: Prowlarr reconciles
what an application holds against what it defines and tries to remove
entries it does not recognize, which Mylar rejects with
`MylarException Code 460`, aborting the rest of that application's sync. Only
the real NZBHydra2 entry belongs in those seeds.

## First-run setup

Jellyfin, Audiobookshelf, Calibre's content server, and Calibre-Web all ship
with no usable account at all until their own first-run setup wizard has
been completed once, normally a manual, one-time click-through in a
browser. `scripts/wire-connections.sh` attempts to complete each one
automatically, using the same placeholder username = password = app name
convention as everywhere else, so `scripts/rotate-*.sh` always has an
account to rotate. Three of the four (Audiobookshelf, Calibre's content
server, Calibre-Web) are reliable, verified across repeated fresh-clone
runs. Jellyfin is not: see its entry below.

- **Jellyfin**: drives the same `/Startup/Configuration` → `/Startup/User`
  → `/Startup/RemoteAccess` → `/Startup/Complete` sequence the setup wizard
  itself calls, then creates an API key and writes it to
  `configs/jellyfin/secrets/api_key.txt` (the only record of Jellyfin's
  current key). No media libraries are configured; none are required to
  complete the wizard, and adding them is a real choice left to you.
  **This one is unreliable**: `/Startup/User` only succeeds once Jellyfin's
  own `UserManager` has lazily created its internal placeholder user
  (`InvalidOperationException: Sequence contains no elements` otherwise),
  and in repeated testing against genuinely fresh containers, that never
  happened even after 10 continuous minutes of retrying, with no clear
  trigger identified. When it doesn't complete in the 180s this script
  waits, it skips with a note (the expected outcome, not a rare edge case)
  and prints how to finish it: visit `http://localhost:${JELLYFIN_HTTP_PORT}/`
  once in a browser (which reliably completes the wizard immediately),
  then re-run `make wire_connections` and `make rotate_all SERVICE=jellyfin`.
- **Audiobookshelf**: calls its own documented `POST /init` endpoint to
  create the `root` user.
- **Calibre's content server**: creates its own SQLite user via the
  documented, non-interactive `calibre-server --manage-users -- add`
  command; this is a separate account from the desktop GUI/noVNC login,
  which already works out of the box from its own committed secret file.
- **Calibre-Web**: sets `config_calibre_dir` directly in `app.db` (while
  stopped) to this stack's shared Calibre library, so the container isn't
  stuck redirecting every request to its own `/admin/dbconfig` setup page.
  Deliberately does **not** configure Calibre-Web's own HTTPS or rename its
  default user (image default: `admin`); both were tried, and reproducibly
  wiped the entire `user` table (including the built-in "Guest" row) on the
  next start, for a reason not identified in the time available. Calibre-Web
  is therefore only ever reachable here over plain HTTP directly, or through
  nginx's own HTTPS termination.

Every one of these checks first-run state before acting (Jellyfin's
`StartupWizardCompleted`, Audiobookshelf's `isInit`, a `calibre-server
--manage-users -- list` check, Calibre-Web's `config_calibre_dir` column),
so re-running `make wire_connections` after any of these has already been
set up just confirms it and moves on.

## What's already wired, and why this script doesn't touch it

- **Bazarr → Sonarr/Radarr**: `configs/bazarr/config/config/config.yaml.example`
  already ships `ip`/`port`/`base_url`/`ssl` filled in, and `apikey` matches
  Sonarr/Radarr's own placeholder key by construction (both derive from the
  same per-app canonical placeholder).
- **Mylar/LazyLibrarian → qBittorrent/SABnzbd**: their `config.ini.example`
  files are pre-filled the same way, since both apps are configured from a
  flat file rather than a database.

## Credentials this script sets up

Beyond the connections above, `ensure_arr_host_prereqs()` (used internally by
the download-client wiring) is the only place in this stack that creates an
arr app's initial WebUI login. Nothing else does this today: neither
bootstrap's config seeding (which only touches files, and this setting lives
in the database) nor `scripts/rotate-passwords.sh` (which only *rotates* an
existing login, and aborts if one isn't there yet). The seeded username and
password both equal the app's own name, matching the README's login table;
rotate it like any other seeded credential with `make rotate_passwords
SERVICE=<app>`.

## Troubleshooting

Run `make wire_connections` directly to see per-app output. A line like
`[lidarr] Not reachable, skipping.` means the app's container either doesn't
exist (its `*_PROFILE` is `disabled`) or didn't come up healthy within 3
minutes; nothing else in this document applies until it's addressed
separately. Every other failure surfaces the app's own validation error, if
any: rerun `./scripts/wire-connections.sh` directly (not the `make` wrapper)
to see the full curl output instead of a truncated summary.
