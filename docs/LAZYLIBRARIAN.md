# LazyLibrarian

LazyLibrarian is the books, audiobooks, and comics tracker/manager in this stack.

## Custom image

The upstream image uses `DOCKER_MODS: ghcr.io/linuxserver/mods:universal-calibre`,
which downloads and installs Calibre at every container start. This adds several
minutes to every restart.

This stack builds a custom image that pre-installs Calibre at build time using a
multi-stage Dockerfile that copies `calibre.txz` directly from the mod image and
runs `calibre_postinstall`. The result is a container that starts in seconds.

### Rebuild

Rebuild the image after pulling a new base image version or after changing
`LAZYLIBRARIAN_VERSION` in `.env`:

```shell
make build_images
```

Then recreate the container:

```shell
podman stop lazylibrarian && podman rm lazylibrarian && make start
```

### Dockerfile

`build/lazylibrarian/Dockerfile`: multi-stage build copying `calibre.txz` from
`docker.io/linuxserver/mods:universal-calibre` and installing the system library
dependencies required by Calibre before extracting the bundle.

---

## Session cookie scoping

LazyLibrarian and Mylar are both cherrypy apps that default to a session
cookie literally named `session_id`, scoped to `Path=/` unless told
otherwise. Left alone, the browser holds only one `session_id` cookie for
the whole domain, so visiting one app overwrites the other's session; the
app whose cookie got overwritten then bounces every subsequent request back
to its own login page, indistinguishable from a real login bug. `nginx`'s
`/lazylibrarian/` and `/mylar/` locations in
`configs/nginx/templates/default.conf.template` each carry a
`proxy_cookie_path` rewrite that scopes the cookie to its own prefix,
which stops the collision.

## NZBHydra2 connection

LazyLibrarian and NZBHydra2 both run on the `apps` network and reach each other
by container alias, but `NZBHYDRA2_PROFILE` defaults to `disabled` (see
`.env.example`), so the committed `config.ini.example` carries no NZBHydra2
provider entry at all: a seeded entry pointing at a container that never
starts by default is worse than none, since it just shows up as a permanently
broken provider in the UI.

If you enable `NZBHYDRA2_PROFILE`, add a Newznab provider yourself in
LazyLibrarian's Search Providers settings (stop LazyLibrarian first per
"Editing the config" below if you're editing `config.ini` directly, or use the
running app's own UI/API instead, which needs no restart):

```ini
[Newznab_0]
dispname = NZBHydra2 (Newznab)
enabled = True
host = https://nzbhydra2:5077/nzbhydra2
api = <your NZBHydra2 API key>
generalsearch = search
```

Add it as Newznab only, not Torznab: NZBHydra2 speaks the wrong protocol for
usenet indexing over Torznab and would only duplicate results.

---

## Book sources

The committed `config.ini.example` ships only the indexer plumbing: numbered
Torznab entries pointing at Prowlarr (created by `scripts/wire-connections.sh`,
not present in the committed file itself). It configures no direct book
sources and no NZBHydra2 connection, so LazyLibrarian starts with nothing
enabled beyond what you add yourself.

LazyLibrarian supports several source types of its own (`[GEN_*]` generic
providers, plus per-service sections). Adding one means deciding what you are
entitled to download from it, which is your call to make rather than something
this repo should preselect. Refer to the
[upstream LazyLibrarian project](https://gitlab.com/LazyLibrarian/LazyLibrarian)
for the section keys each provider type expects.

## Folders

`config.ini.example` sets `download_dir` to
`/data/downloads,/data/torrents/ebooks,/data/usenet/complete/ebooks`: its own
direct downloads, then where qBittorrent's `lazylibrarian` category and
SABnzbd's `ebooks` category finish, so post-processing finds what each client
downloaded. LazyLibrarian splits the list on bare commas. `ebook_dir` is
`/data/media/calibre-library`: with the Calibre import on
(`imp_calibre_ebook`), LazyLibrarian looks for the imported book there after
`calibredb add`, and under any other folder it marks the import Failed and
downloads the book again (#554). `make wire_connections` adds the missing
download folders to an existing `config.ini`, keeping any added by hand, and
moves `ebook_dir` to the Calibre library only while it is still the old
default `/data/media/ebooks` and the Calibre import is on.

## Audiobook file types

`audiobook_type` in `config.ini.example` lists `m4b, m4a, mp3, flac, opus,
ogg, aac`: the formats audiobook releases come in that Audiobookshelf plays.
LazyLibrarian checks a release's files against it before snatching, and turns
down one with none of these types (`has no AudioBook files (m4a)` in its log),
so a missing type keeps a book Wanted. `make wire_connections` adds any listed
type an existing `config.ini` lacks and removes none, so a type added by hand
stays (see [CONNECTIONS.md](CONNECTIONS.md)).

## Editing the config

LazyLibrarian writes its in-memory config back to disk on shutdown. Editing
`config.ini` while the container is running and then restarting will cause
the container's in-memory state to overwrite the file on shutdown. Always stop
the container before editing:

```shell
podman stop lazylibrarian
# edit config.ini
podman start lazylibrarian
```

---

See also: [README.md](../README.md), [docs/MAKE_COMMANDS.md](MAKE_COMMANDS.md)
