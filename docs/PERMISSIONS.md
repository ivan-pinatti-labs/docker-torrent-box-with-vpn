# Permissions Model

This stack uses rootless Podman plus service-specific non-root application IDs.
The source of truth is `permissions.yml`; do not hand-edit ownership as a quick
fix unless the manifest is wrong.

## Commands

```sh
make permissions_check
make permissions_repair
make permissions_smoke
make permissions_host_smoke
```

`make start`, `make start_library`, and `make start_observability` all depend
on `permissions_repair`, so the recursive repair runs before any of those
targets start containers. With rootless Podman, host uid 1000 maps to uid 0
inside the container namespace, so repair commands must run through
`podman unshare`.

`make permissions_host_smoke` verifies that the host operator can create, edit,
move, and delete files under manifest-managed directories without `sudo`.

To preview what a repair would run without changing anything, call the script
directly with the `dry-run` command. It prints every `mkdir`, `chown`, `chmod`,
and `setfacl` invocation instead of executing them:

```sh
./scripts/permissions.py dry-run --runtime podman --recursive
```

## Design Rules

- Each app gets its own uid/gid from `permissions.yml` and `.env`.
- Shared data stays mounted broadly enough for hardlinks to work.
- Write access is narrowed with directory ownership plus POSIX ACLs.
- The host operator keeps `rwx` ACL access on every managed path. In rootless
  Podman this is represented as namespace uid `0`, which maps back to the host
  login user.
- Read-only mounts are used for config that a container should not mutate.
- LinuxServer and hotio images may start container init as root, but the app
  process must drop to its service-specific `PUID:PGID`.
- Containers that do not need root are pinned with `user: UID:GID`.

## Core Mapping

Downloaders own their own incoming areas:

| Path | Owner | Extra Write ACL |
| --- | --- | --- |
| `data/torrents/tv` | `qbittorrent` | `sonarr` |
| `data/torrents/movies` | `qbittorrent` | `radarr` |
| `data/torrents/music` | `qbittorrent` | `lidarr` |
| `data/torrents/ebooks` | `qbittorrent` | `readarr`, `lazylibrarian` |
| `data/torrents/comics` | `qbittorrent` | `readarr`, `mylar` |
| `data/torrents/mature` | `qbittorrent` | `whisparr` |
| `data/usenet/complete/tv` | `sabnzbd` | `sonarr` |
| `data/usenet/complete/movies` | `sabnzbd` | `radarr` |
| `data/usenet/complete/music` | `sabnzbd` | `lidarr` |
| `data/usenet/complete/ebooks` | `sabnzbd` | `readarr`, `lazylibrarian` |
| `data/usenet/complete/audiobooks` | `sabnzbd` | `readarr`, `lazylibrarian` |
| `data/usenet/complete/comics` | `sabnzbd` | `readarr`, `mylar` |
| `data/usenet/complete/mature` | `sabnzbd` | `whisparr` |
| `data/usenet/complete` | `root` | `sabnzbd` |
| `data/usenet/blackhole` | `root` | `sabnzbd`, `nzbhydra2`, `lazylibrarian` |
| `data/downloads` | `jdownloader2` | `lazylibrarian`, `mylar` |
| `data/downloads/comics` | `jdownloader2` | `mylar` |
| `data/downloads/mature` | `jdownloader2` | none |
| `data/downloads/musicVideos` | `jdownloader2` | none |

Importers own only their target libraries and recycle folders:

| Path | Owner | Extra ACL |
| --- | --- | --- |
| `data/media/tv` | `sonarr` | `bazarr` write, `jellyfin` read |
| `data/media/movies` | `radarr` | `bazarr` write, `jellyfin` read |
| `data/media/music` | `lidarr` | `jellyfin` read |
| `data/media/musicVideos` | `root` | `jellyfin` read |
| `data/media/ebooks` | `readarr` | `lazylibrarian` write, `audiobookshelf` read, `calibre` write |
| `data/media/audiobooks` | `readarr` | `lazylibrarian` write, `audiobookshelf` read |
| `data/media/comics` | `readarr` | `mylar` write, `calibre` read |
| `data/media/mature` | `whisparr` | `jellyfin` read |
| `data/media/podcasts` | `root` | `audiobookshelf` write |
| `data/media/calibre-library` | `calibre` | `calibre_web` read |
| `configs/calibre/library-db` | `calibre` | `calibre_web` write |
| `configs/korsync/data` | `korsync` | |

Two app-owned trees sit under `data/` without being libraries. Each app writes
only its own subdirectory, so these follow the `configs/<app>/config` ownership
pattern rather than the shared-library one above, with no cross-app ACLs:

| Path | Owner | Mounted at |
| --- | --- | --- |
| `data/media/covers/<app>` | that app | `/config/MediaCover` |
| `data/backups/<app>` | that app | `/config/Backups` |

`<app>` is `sonarr`, `radarr`, `readarr`, `lidarr` or `whisparr` for covers,
plus `prowlarr` for backups. Neither has an app setting to relocate it, so both
are bind mounts back over the app's own config paths. See
[STORAGE.md](STORAGE.md) for why they live out here.

Service-specific config, cache, and storage paths are declared in
`permissions.yml` as well. Add new writable paths there before mounting them
read-write in compose.

## Host Operator Access

`permissions.yml` has a global `host_access` rule. It grants namespace uid `0`
`rwx` access and default `rwx` inheritance on every managed directory. Under
rootless Podman, namespace uid `0` maps to the host login user, so normal shell
operations such as editing a config file, watching media, moving a folder, or
deleting a bad download work without `sudo`.

This does not replace service-specific ownership. The owning service still owns
its library or config directory, and importer ACLs still control which
containers can write. The tradeoff is that root processes inside rootless
containers also appear as namespace uid `0`; that is inherent to rootless UID
mapping and is why app processes still run as service-specific non-root UIDs.

## External Storage

On filesystems that carry no per-file ownership or POSIX ACLs (CIFS/SMB, FAT
variants, NTFS), `scripts/permissions.py` skips `chown`, `chmod` and `setfacl`
for the affected paths and prints a note, while still creating the directories
and still running the hardlink smoke test. Access there comes from the mount
options instead. `check` and `repair` both behave this way, so `make start`
continues to work when `data/` is on one of them.

NFS is **not** in that group. It carries real uid/gid and supports ACLs, so the
manifest applies there exactly as it does on local disk, which is why
[STORAGE.md](STORAGE.md) offers it as the alternative to SMB. That assumes the
export cooperates: one that squashes root, or a server without NFSACL/NFSv4 ACL
support, will reject the `chown` or `setfacl` and the run stops with that
error. For a setup chosen specifically to preserve ownership, failing loudly
beats silently leaving the tree to whatever the export decided.

## Hardlinks

Hardlinks require source and target to be on the same filesystem and require the
importing uid to have access to the downloader-created source file. The manifest
sets default ACLs on category directories so new downloader files inherit the
right importer access.

`make permissions_smoke` creates a temporary file as the downloader owner, then
tries to hardlink it as the importer uid for the declared media paths.

## Known Alignment

SABnzbd category `ebooks` maps to `data/usenet/complete/ebooks`. Readarr's
SABnzbd download client is configured to use the same category.

---

See also: [README.md](../README.md), [docs/MAKE_COMMANDS.md](MAKE_COMMANDS.md)
