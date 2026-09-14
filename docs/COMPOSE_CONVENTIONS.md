# Compose file conventions

Every service block across the `docker-compose-*.yml` files follows the same
key order. This keeps services easy to scan and diffs easy to review: once you
know the order, you know where to look for any given setting, regardless of
which file or service you're reading.

## Canonical key order

```text
<<: *anchor(s)      # YAML merge key(s), always first line when present
deploy              # only when written explicitly (override, or no anchor)
image
build               # rare, only services with a local Dockerfile
container_name
depends_on          # only network_mode-based services with a hard dependency
profiles
networks / network_mode
ports
sysctls
restart
stop_grace_period
stop_signal
privileged
userns_mode
user
security_opt
cap_drop
cap_add
devices
entrypoint
command
env_file
environment
secrets             # compose `secrets:` the service consumes
volumes
healthcheck
memswap_limit       # disabled services only, sits with deploy at the top
```

Reasoning for the less obvious placements:

- `environment`, `volumes`, and `healthcheck` come last because they're
  typically the longest blocks in a service definition; keeping them at the
  end means the shorter, more identity/security-relevant keys (`image`,
  `networks`, `security_opt`, etc.) are visible without scrolling.
- `command`/`entrypoint` sit with the other short "how the process starts"
  keys, right before `env_file`, rather than being grouped with the long tail.
- `secrets` follows `environment` because it's the third and last source of
  configuration a service receives, and reads naturally after the variables
  that reference the mounted paths.
- `deploy` and `memswap_limit` are resource-limit keys. When a service
  declares one explicitly instead of (or as an override on top of) a shared
  `x-limit-*` anchor, it stays at the very top, immediately after the merge
  key, since that's conceptually where the anchor's own `deploy` key would sit.
- Disabled/commented-out service blocks, and inline commented-out fragments
  (e.g. a `# ports:` block kept for reference), follow the same order as if
  they were active, so re-enabling a service later doesn't require another
  reorder pass.

## Example

```yaml
sonarr:
  <<: [*servarr-common, *limit-servarr]
  image: docker.io/linuxserver/sonarr:${SONARR_VERSION}
  container_name: sonarr
  profiles: ["${SONARR_PROFILE}"]
  networks:
    apps:
      aliases: [sonarr-http]
    services: {}
  env_file: ["${CONFIG_FOLDER}/sonarr/.env"]
  environment:
    <<: *servarr-env
    PGID: "${SONARR_GID}"
    PUID: "${SONARR_UID}"
  volumes:
    - /etc/localtime:/etc/localtime:ro
    - ${CERTIFICATES_FOLDER}:/certs:ro
    - ${CONFIG_FOLDER}/sonarr/config:/config:z
    - ${DATA_FOLDER}:/data:z
  healthcheck:
    <<: *healthcheck-defaults
    test: curl --fail http://127.0.0.1:${SONARR_HTTP_PORT}/sonarr/ || exit 1
```

## Secrets override pattern

Most services keep a single, committed `configs/<service>/.env` file (empty or
holding non-sensitive defaults). For a service whose `.env` needs to carry
real secrets (API keys, SMTP passwords, tokens), split it into two files
instead of committing the secret:

- `configs/<service>/.env`, a committed template with realistic but fake
  placeholder values, so the format stays self-documenting.
- `configs/<service>/.env.secrets`, real values, gitignored, never
  committed. Seeded on first `make bootstrap` from a committed
  `configs/<service>/.env.secrets.example` stub if it doesn't already exist,
  so `env_file` always resolves to a real path on a fresh clone.

Wire both into `env_file` as a two-item list, template first so the secrets
file overrides it (Compose merges `env_file` entries in order; later files
win on duplicate keys):

```yaml
env_file: ["${CONFIG_FOLDER}/grafana/.env", "${CONFIG_FOLDER}/grafana/.env.secrets"]
```

The service's `.gitignore` should except `.env` and `.env.secrets.example`,
but never `.env.secrets`. It stays caught by the blanket `*` rule (and the
root `.gitignore`'s `.env.*` pattern as a backstop). See `configs/grafana/`
for a working example.

## Secrets shared by more than one service

The pattern above works when only one container needs a value. It breaks down
as soon as a second one does, because `env_file` delivers `NAME=value` and
cannot rename: each image insists on its own spelling. SABnzbd's API key is
wanted as `SABNZBD_API_KEY` by SABnzbd, `SABNZBD_APIKEYS` by its exporter, and
`HOMEPAGE_VAR_SABNZBD_API_KEY` by homepage. Copying the value into three
`.env` files is what this pattern exists to avoid.

Compose `secrets:` solves it because it delivers a **path** rather than a
value, leaving each consumer to name it. The file lives in the directory of
the service that owns the credential, named `<thing>.txt` because its contents
are one bare value rather than `KEY=value`.

A secret is declared identically, in full, in **every** compose file that has
an owning or consuming service for it, not once in a shared parent. Each
declaration repeats the same `file:` path, so the block is a few duplicated
lines rather than a single shared one, in exchange for every compose file
being usable standalone: `podman-compose -f docker-compose-X.yml up` resolves
its own secrets without needing `docker-compose.yml` or any other file in
scope. (A single declaration in `docker-compose.yml`, relying on `include:` to
make it resolvable everywhere, was tried first and works, but ties every
consuming file's correctness to always being invoked through the aggregate;
see the git history on this file if you want the details.)

```yaml
# docker-compose-nzb.yml: owns the secret (sabnzbd issues the key)
secrets:
  sabnzbd_api_key:
    file: ./configs/sabnzbd/secrets/api_key.txt
    x-podman.relabel: z    # required on SELinux hosts
```

```yaml
# docker-compose-proxy.yml: consumes it, declares an identical copy
secrets:
  sabnzbd_api_key:
    file: ./configs/sabnzbd/secrets/api_key.txt
    x-podman.relabel: z

services:
  homepage:
    environment:
      - HOMEPAGE_FILE_SABNZBD_API_KEY=/run/secrets/sabnzbd_api_key
    secrets: [sabnzbd_api_key]
```

The top-level `secrets:` block goes before `services:` in each file (and
before `include:` in `docker-compose.yml`, for files that use it), so
declarations are read before their use.

Rules that are easy to get wrong:

- **Never put a secret in the root `.env`.** Values there land in compose's
  interpolation namespace, which is shared by every service, whereas a
  per-service file or a declared secret reaches only the container that takes
  it. The root `.env` is for non-secret configuration only.
- **Mode 644, and it is not laxness.** Rootless podman maps the host file to
  uid 0 inside the container while the app runs as another UID, so 640 and
  600 leave it unreadable. This matches the existing `.env.secrets` files.
- **Write with `printf`, never `echo`.** The contents are consumed verbatim;
  homepage substitutes a trailing newline straight into its config and the
  credential silently stops working. (A `$(cat ...)` shim strips it, so the
  breakage shows up in only some consumers, which makes it hard to spot.)
- **Duplicate declarations must stay byte-identical.** If two files declare
  the same secret name with a different `file:` path, compose does not
  error, it silently uses whichever declaration was included last. This is
  the risk this pattern trades the old "parent-only declaration" fragility
  for, and it is why every declaration above is annotated with a reminder to
  keep it in sync with its siblings.
- **A missing secret file is a start-time failure, not a config error.**
  `config` passes, then the consuming service dies with
  `statfs ...: no such file or directory`. Other services are unaffected.
  `make bootstrap` seeds the file so a fresh clone works.
- **Consumer support varies, and don't trust an image's own docs.** All
  LinuxServer images accept `FILE__<VAR>=/run/secrets/<name>`; homepage
  accepts `HOMEPAGE_FILE_<VAR>`. Third-party images with neither need an
  entrypoint shim that exports the value before exec'ing the original
  command, as `sabnzbd_exporter` does. jlesage's baseimage-gui documents a
  `CONT_ENV_<VAR>` Docker-secrets convention that does not actually work in
  the `jdownloader-2` image (its Dockerfile pre-declares the target vars as
  empty strings, which defeats the loader's own "only set if unset" check;
  confirmed by reading `/init`'s source, and by a live rotation that
  silently kept authenticating with the old password). When neither an env
  convention nor a shim will do, bind-mount a patched version of the
  specific cont-init.d script that reads the secret file directly, the same
  idiom `patches/mylar/` already uses for source patches (see
  `docs/MYLAR.md`). On SELinux hosts such a volume mount needs `:ro,z` like
  any other bind mount, not just the `x-podman.relabel: z` on the `secrets:`
  declaration.

  jdownloader-2 was the worked example here until 2026-09-02, carrying
  `patches/jdownloader2/10-webauth.sh` over the image's own
  `/etc/cont-init.d/10-webauth.sh`. `baseimage-gui` 4.13.0 fixed the loader
  by giving it a `force` argument that secrets pass, and the pinned image was
  already built on 4.13.1, so the patch was dropped; see issue #107. The
  technique stands, the example is simply no longer live.
- The owning service's `.gitignore` needs `!secrets/`, `secrets/*` and
  `!secrets/*.example`, so real values stay ignored while the `.example`
  templates commit. `scripts/seed-secrets.sh` seeds them on bootstrap.

## Runtime config bootstrap pattern

Some apps own a plain-text config file that they read at startup and rewrite
on shutdown (`config.xml` for the servarr apps, `config.ini` for
lazylibrarian and mylar, `nzbhydra.yml`, Jackett's `ServerConfig.json`, even a
plain `.env` like grafana's). Tracking the live file directly means every API
key, web UI password, or forwarded credential (SABnzbd, qBittorrent, NZBGet,
Prowlarr, ComicVine, ...) it accumulates sits in git in the clear, and the
apps rewriting it on their own schedule turns ordinary `git diff` noise into
a risk (see the pre-commit stash corruption note under "Editing runtime app
state" in `AGENTS.md`).

The fix mirrors the secrets override pattern above, minus the split-file
part, since these aren't loaded via `env_file`:

- `configs/<app>/<path-to-file>.example`, committed, same structure as the
  live file, with every credential-bearing field (API keys, web UI/service
  passwords, SSL cert passwords, third-party API keys) swapped for an
  obviously-fake placeholder. Everything else (ports, `UrlBase`, feature
  flags, indexer hostnames) is copied verbatim: it isn't a secret, and
  matches the plain-commit case for files like `prometheus.yml`.
- The live file (`config.xml`, `config.ini`, `nzbhydra.yml`, `.env`, ...)
  is gitignored: the per-app `.gitignore`'s allowlist (`!config/...`)
  points at the `.example` path instead of the live one.
- `scripts/seed-configs.sh <live-file>` copies `<live-file>.example` to
  `<live-file>` the first time it's missing, mirroring
  `scripts/seed-secrets.sh`'s copy-if-missing behavior (including the
  interactive skip/diff/replace prompt when the live file already exists,
  and doing nothing in a non-interactive run). One call per app is wired into
  the `bootstrap:` Makefile target, ordered before `generate_certificate`
  needs the file to exist.

Where a cross-app credential appears in more than one `.example` (e.g.
Prowlarr's API key, forwarded into lazylibrarian's and mylar's Torznab
indexer entries), the same placeholder value is reused across all of them,
so a fresh bootstrap is at least internally consistent even though the real
wiring still has to happen through each app's own UI.

`make generate_certificate` already patches the SSL cert password into every
seeded file that needs one (via `xmlstarlet` for the XML configs, `yq` for
`nzbhydra.yml`), so the placeholder value in the `.example` is never what a
running container actually sees.

## Shared anchors

`docker-compose-servarr.yml`'s `x-servarr-common` anchor bundles the keys
common to most servarr services (`networks`, `sysctls`, `restart`,
`security_opt`, `environment`, `volumes`) and follows this same key order
internally, so services that merge it in (`<<: [*servarr-common, ...]`) stay
consistent with services that don't use the shared anchor.

---

See also: [README.md](../README.md), [docs/MAKE_COMMANDS.md](MAKE_COMMANDS.md)
