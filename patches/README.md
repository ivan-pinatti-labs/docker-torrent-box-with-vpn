# Patches

Vendored source files from upstream projects, mounted into their containers to
replace the shipped copies at runtime. Each subdirectory mirrors the upstream
layout so a bind mount lands the file in the right place.

**These files are not covered by this repository's Apache License 2.0.** They
remain under their original upstream licenses, and are redistributed here
under those terms. See [NOTICE.md](../NOTICE.md).

## Contents

| Directory | Upstream project | Upstream license | Contents |
| --- | --- | --- | --- |
| `mylar/` | [MylarComics/mylar3](https://github.com/mylarcomics/mylar3) | GPL-3.0-or-later | Five complete source files, modified to add qBittorrent HTTPS support (self-signed certificate handling in the torrent client and its config UI) |
| `sabnzbd/` | [linuxserver/docker-sabnzbd](https://github.com/linuxserver/docker-sabnzbd) | GPL-3.0 | `svc-sabnzbd/run`, the image's own s6 service script, changed to pass `--server` only when the configured host is missing, loopback or `::` (the image's own default). Upstream passes it unconditionally, and it overrides `host` in `sabnzbd.ini` and is persisted back into it, so `host = 0.0.0.0` cannot survive a start |

`mylar/mylar/config.py` and `mylar/mylar/webserve.py` carry their original GPL
headers. Do not strip them. Because these are complete GPL-3.0 files rather
than small excerpts, anyone redistributing this repository is bound by GPL-3.0
for the contents of `mylar/`, regardless of the Apache License 2.0 covering
the rest.

## Why these are vendored rather than forked

Each patch tracks a specific upstream fix that is not yet in a release the
stack can pin. `docs/MYLAR.md` records the upstream commit each Mylar patch
corresponds to, so the whole directory can be deleted once a release carries
the change. An issue labelled `upstream-blocked` tracks each removal.

## Tooling

`patches/` is excluded from the linters and secret scanners in
`.pre-commit-config.yaml`. Upstream code is not ours to reformat, and its
credential-handling code paths produce nothing but false positives.
