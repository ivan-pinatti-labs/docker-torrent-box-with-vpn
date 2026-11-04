# Backup and Restore

This project has two backup modes:

- `make backup` or `make backup-configs`: lean backup for day-to-day recovery.
- `make backup-full`: larger backup that keeps Jellyfin's metadata library.

Both are manual. Run `make backup-schedule` to install a cron entry that runs
`make backup` automatically (daily at 03:00 by default). See
[Scheduling](#scheduling) below.

Stop the containers before backing up or restoring if you need database-consistent
archives:

```shell
make stop
```

## Config Backup

Use the default backup for regular operational recovery:

```shell
make backup
```

This creates:

```text
backup/configs-YYYY-MM-DD-HHMMSS.tar.gz
```

The config backup includes `.env`, `certs/`, and `configs/`, but skips heavy or
regenerable runtime state such as media artwork, metadata caches, logs, Sentry
state, app-generated backup archives, transient SQLite WAL/SHM files, and cloned
Recyclarr resource repositories.

Audiobookshelf stores app backups under `/metadata/backups`, and those backups
can include state and images from `/metadata/items` and `/metadata/authors`.
The full `/metadata` tree is bind mounted on the host at
`configs/audiobookshelf/metadata` and included in the config backup.

Cleanuparr keeps everything it knows, its settings, strikes and the keys of the
apps it connects to, in SQLite databases under `configs/cleanuparr/config`, and
its own login and API key in `configs/cleanuparr/secrets`. Both are in the
config backup like any other app's; nothing of its lives anywhere else.

Use this when you want the smallest practical backup that can restore service
settings, secrets, certificates, and primary app databases.

## What Neither Mode Covers

Two things the *arr apps used to keep inside `configs/` now live under `data/`
instead, so **no backup mode archives them**:

| What | Where it lives now | `.env` variable |
| ---- | ------------------ | --------------- |
| Cover art (`/config/MediaCover`) | `data/media/covers/<app>` | `MEDIA_COVERS_FOLDER` |
| Scheduled database backups (`/config/Backups`) | `data/backups/<app>` | `APP_BACKUPS_FOLDER` |

Both are bind mounted back over the app's own config paths, so the apps are
unaware of the move. Cover art is regenerable: the apps refetch it on a
metadata refresh. The scheduled backups are not, and they are deliberately out
here so they survive losing the host that `configs/` sits on. Whatever storage
`data/` is on is responsible for them; see [STORAGE.md](STORAGE.md).

The primary databases themselves stay in `configs/` and are covered by both
backup modes.

## Full Config Backup

Use the full mode when you also want Jellyfin's metadata library:

```shell
make backup-full
```

This creates:

```text
backup/full-YYYY-MM-DD-HHMMSS.tar.gz
```

The full backup includes `.env`, `certs/`, and all of `configs/`, including
Jellyfin's metadata library. Caches are **not** among them: `--exclude=cache`
is unanchored and applies to both modes, so any directory named `cache` is
dropped wherever it appears. That is deliberate, since the largest of them
hold regenerable transcodes. It also does not include repository metadata,
tests, media/download libraries, observability storage, or dependencies.

## Scheduling

```shell
make backup-schedule
```

In a real terminal, this prompts for how often (daily or weekly, default
daily) and what time (default 03:00), then installs a cron entry that runs
`make backup` on that schedule, logging to `logs/backup.log`. Run in a
non-interactive context, it applies the default (daily at 03:00) without
prompting.

The scheduled backup runs live, without stopping the stack first (unlike
the "stop containers first" recommendation above for a database-consistent
snapshot), so it favors staying non-disruptive over perfect consistency. If
you want a stop-backup-start cycle instead, script that separately with
`make stop && make backup && make start` on your own cron schedule.

Re-running `make backup-schedule` replaces the previously scheduled entry
rather than stacking a second one. See it any time with `crontab -l`; remove
it with `crontab -l | grep -v 'schedule-backup.sh' | crontab -`. This only
schedules `make backup` (the lean mode); for `make backup-full` on a
schedule, add your own cron line instead.

## Restore

Restore requires an explicit archive path:

```shell
make restore-configs BACKUP=backup/configs-YYYY-MM-DD-HHMMSS.tar.gz
```

or:

```shell
make restore-full BACKUP=backup/full-YYYY-MM-DD-HHMMSS.tar.gz
```

Before replacing local state, restore creates a safety archive:

```text
backup/pre-restore-YYYY-MM-DD-HHMMSS.tar.gz
```

The restore command replaces `.env`, `certs/`, and `configs/` from the archive.
Stop containers first, restore the archive, then start the stack again.

```shell
make stop
make restore-configs BACKUP=backup/configs-YYYY-MM-DD-HHMMSS.tar.gz
make start
```

## What Is Not Backed Up

Neither backup mode includes media/download libraries or repository-only state:

- `.git/`
- `tests/`
- `data/` (includes `data/media/`, the actual media library)
- `storage/`
- `cache/`
- `logs/`
- `node_modules/`

Back up media libraries separately with a storage-level or filesystem backup
tool if you need disaster recovery for downloaded media.
