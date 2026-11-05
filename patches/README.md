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
| `sabnzbd/` | [linuxserver/docker-sabnzbd](https://github.com/linuxserver/docker-sabnzbd) | GPL-3.0 | `svc-sabnzbd/run`, the image's own s6 service script, changed to pass `--server` only when the configured host is missing, loopback or `::` (the image's own default). Upstream passes it unconditionally, and it overrides `host` in `sabnzbd.ini` and is persisted back into it, so `host = 0.0.0.0` cannot survive a start |

`mylar/` was here until Mylar v0.11.0 shipped its qBittorrent HTTPS fix
(MylarComics/mylar3#23), and went with #106.

## Why these are vendored rather than forked

Each patch tracks a specific upstream fix that is not yet in a release the
stack can pin, so the directory can be deleted once a release carries the
change. An issue labelled `upstream-blocked` tracks each removal.

## Tooling

`patches/` is excluded from the linters and secret scanners in
`.pre-commit-config.yaml`. Upstream code is not ours to reformat, and its
credential-handling code paths produce nothing but false positives.
