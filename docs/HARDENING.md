# Container Security Hardening

This document describes the security measures applied to containers in this stack and the
rationale behind each decision.

## Threat model

The stack runs on a single host behind a LAN. The goal is containment: if a container is
compromised (e.g. via a vulnerability in a media app), the attacker should not be able to
escalate to the host user, read unrelated container data, or gain Linux capabilities they
do not need.

## Measures applied

### Non-root process user (PUID/PGID)

All linuxserver.io and hotio images accept `PUID` and `PGID` environment variables. The
container init (s6-overlay) starts as root to set up the environment, then drops to the
configured user before exec'ing the application. Setting `PUID=${UID}` and `PGID=${GID}`
means the running application is uid=1000, not uid=0.

`PUID=0`/`PGID=0` (which was the previous default) defeats this entirely: the application
itself runs as root inside the container.

For images that use a `user:` field instead of PUID/PGID (recyclarr, prometheus, grafana),
the same principle applies via the Compose `user:` key.

### `no-new-privileges`

```yaml
security_opt:
  - no-new-privileges:true
```

Applied to every container except gluetun, cadvisor, podman_exporter, and
podman_limits_exporter (see exceptions below). Prevents any process inside the container
from gaining additional privileges via setuid/setcap binaries or execve. This is a
kernel-level guarantee and is safe for all images in this stack.

### `cap_drop: ALL`

```yaml
cap_drop: [ALL]
```

Applied to containers whose init does not need Linux capabilities to function:

| Container(s) | cap_drop applied | Reason |
| --- | --- | --- |
| nginx | `cap_drop: ALL` + `cap_add: [CHOWN, SETUID, SETGID, NET_BIND_SERVICE]` | Master chowns temp dirs, forks workers as `nginx` user (uid 101), and binds to ports 80/443 |
| alloy | `cap_drop: ALL` + `cap_add: [DAC_READ_SEARCH]` | Needs to read log files owned by other services' PUIDs |
| prometheus, grafana, loki | yes | Static binary / Go service |
| node_exporter, nginx_exporter, qbittorrent_exporter, sabnzbd_exporter | yes | Read-only exporters |
| recyclarr, flaresolverr, homepage, audiobookshelf, korsync, log_rotator | yes | No s6-overlay privilege switching |

**Not applied** to linuxserver/hotio images (sonarr, radarr, jellyfin, qbittorrent, sabnzbd,
legacy nzbget, etc.): s6-overlay needs `CAP_CHOWN` to transfer `/config` ownership to PUID,
and `CAP_SETUID`/`CAP_SETGID` to drop from uid=0 to PUID. Dropping all capabilities before
those operations silently prevents the privilege switch, leaving the app running as root
regardless of the PUID setting.

### IPv6 disabled

```yaml
sysctls:
  - net.ipv6.conf.all.disable_ipv6=1
  - net.ipv6.conf.default.disable_ipv6=1
  - net.ipv6.conf.lo.disable_ipv6=1
```

Applied to standalone services and exporters. Prevents accidental traffic from
bypassing the VPN via IPv6 where a container has its own network namespace.

`qbittorrent`, `sabnzbd`, and legacy `nzbget` inherit gluetun's network
namespace, so their container-level IPv6 settings are controlled by gluetun.
Gluetun intentionally keeps IPv6 sysctls enabled because its DNS listener binds
to `[::]:53`; leak protection comes from not assigning IPv6 addresses and from
gluetun's firewall rules. SABnzbd is additionally configured with
`ipv6_hosting = 0` and `ipv6_servers = 0` in
`configs/sabnzbd/config/sabnzbd.ini`, which is what stops it selecting Usenet
servers over IPv6 or opening the `[::1]` listener.

Its bind address is not ours to set, and expecting otherwise cost a red build on
the 5.0.4 bump. linuxserver's start script passes `--server ::` whenever
`/proc/net/if_inet6` exists, `--server` overrides the config file, and SABnzbd
persists the override back into the ini, so `host = 0.0.0.0` cannot survive a
start. The file exists here because gluetun keeps IPv6 sysctls enabled for its
own DNS listener, per the paragraph above. Reported upstream twice,
[#116](https://github.com/linuxserver/docker-sabnzbd/issues/116) and
[#240](https://github.com/linuxserver/docker-sabnzbd/issues/240), and closed as
intended behavior: forcing it is what stops a user binding `127.0.0.1` and
locking themselves out of the web UI.

Accepting `::` costs nothing here, which is why the test allows either value. The
listener lives in gluetun's network namespace, which is assigned no IPv6 address
and is firewalled, so binding `::` reaches nothing that `0.0.0.0` would not. The
alternatives were both worse: disabling IPv6 in that namespace to make the
container choose `0.0.0.0` would break gluetun's DNS listener, and overriding the
start script would mean vendoring a permanent fork of upstream's launcher to
control a value that protects nothing in this topology.

### VPN kill-switch

Download clients (qbittorrent, jdownloader2, sabnzbd, and legacy nzbget when
enabled) share the gluetun network namespace via
`network_mode: container:${VPN_PROVIDER}`. If gluetun stops, those containers
lose network access entirely. No traffic can escape to the clearnet. The
qBittorrent and SABnzbd exporters do not share the namespace; they sit on
internal networks and scrape the download clients through gluetun's services
address.

### Internal networks

The observability stack and the services network are declared `internal: true`, meaning
containers on those networks cannot route to external addresses. This limits what a
compromised exporter or servarr app can reach.

### Read-only volume mounts

Certificates, config files used only at read time, and system paths are mounted `:ro` where
possible. Examples: `/etc/localtime`, `/certs`, prometheus config.

## Exceptions

| Container | Exception | Reason |
| --- | --- | --- |
| gluetun | `cap_add: [NET_ADMIN, NET_RAW]` | VPN tunnel and firewall rule management |
| cadvisor | `privileged: true` | Requires full cgroup, /proc, and /sys access to report container metrics |
| podman_exporter | `userns_mode: keep-id:uid=65534,gid=65534` | Must access the Podman socket as a specific mapped UID; SELinux label enforcement disabled |
| podman_limits_exporter | `userns_mode: keep-id:uid=0,gid=0` | Must access the Podman socket as a specific mapped UID; SELinux label enforcement disabled |
| gluetun, podman_exporter, podman_limits_exporter | `security_opt: label=disable` | SELinux label enforcement disabled for socket access |

## Rootless Podman UID remapping

This stack runs under rootless Podman. The host user (uid=1000) is mapped to uid=0 inside
container user namespaces. Container uid=1000 maps to a sub-uid (typically host uid
~525287).

**Consequence for bind-mounted volumes:** Files created on the host by the host user appear
as uid=0 inside the container. A container process running as uid=1000 cannot write to
files it sees as owned by uid=0.

**Fix for directories that container processes (uid=1000) must write to**: remap ownership
into the container user namespace before first start. `podman unshare` enters the same user
namespace containers use, so `chown $(id -u):$(id -g)` sets ownership to the sub-uid that
container uid=1000 maps to on the host.

```bash
make bootstrap
```

This covers the managed `data`, `configs`, and `storage` paths declared in
`permissions.yml`. It also applies the initial Jellyfin network settings from
`JELLYFIN_BASE_URL` and `JELLYFIN_KNOWN_PROXY`; normal `make start` does not
rewrite Jellyfin config.

The permissions manifest also grants namespace uid `0` `rwx` ACL access to all
managed paths. In rootless Podman, namespace uid `0` maps to the host login
user, so the operator can edit, move, and delete managed files from a normal
terminal without `sudo` while app processes continue to run as their
service-specific non-root UIDs.

`podman unshare` enters the same user namespace the containers use. Inside it,
`chown $(id -u):$(id -g)` sets ownership to the sub-uid that container uid=1000 maps to on
the host.

**For linuxserver s6-overlay images** (sonarr, radarr, etc.): the init script runs
`chown -R ${PUID}:${PGID} /config` recursively at every startup, so config directories are
automatically re-owned. No manual chown is needed.

**For the hotio whisparr image**: the init only chowns the top-level `/config` directory,
not its contents. `make bootstrap` handles the one-time recursive chown of
`configs/whisparr/config` so the app process can read its own ASP.NET data-protection keys
and write its PID file.

## Keeping credentials out of git

Several layers, because no single one covers the whole problem.

| Layer | When | Scope |
| --- | --- | --- |
| `configs/*/.gitignore` | always | Each starts with a blanket `*` and re-includes only the files that belong in git |
| gitleaks (pre-commit) | every commit | The staged diff only |
| gitleaks (pre-push and CI) | every push, every pull request | Full git history, well under a second for this repo |

Nothing rescans the whole history on every commit. The per-commit layer is
incremental; the full sweep runs at push time and in CI, and at this repo's
size it is not worth optimizing away.

Both layers read `.gitleaks.toml`, so a rule added there applies to the fast
staged-diff check and the CI check alike. Neither reads the working tree: the
commit-stage hook scans the staged diff, and the pre-push and CI scans read git
history. That distinction matters, because a filesystem scan walks the disk and
this working tree holds live credentials by design in gitignored paths, so a
local `gitleaks dir` run reports thousands of findings that are not in git and
never will be.

The history scan is a Go binary that pre-commit builds, deliberately not a
container. Run as `docker run -v $PWD:/src zricethezav/gitleaks:v8.30.1 git`,
gitleaks' own git
subprocess reports `detected dubious ownership in repository at '/src'`, logs
it to stderr, scans zero commits and still exits 0: a secret scan that checks
nothing and reports success. Confirmed against gitleaks v8.30.1.

The `Security Reports` job in PR Validation does run it in a container, because
it needs SARIF output rather than a pass or fail. It sets `safe.directory`
through `GIT_CONFIG_*` to avoid the above, and then asserts the commit count is
not zero, so that failure mode cannot come back silently.

### Findings in the Security tab

`Security Reports` publishes trivy, checkov, gitleaks, hadolint and zizmor
output to GitHub code scanning as SARIF. That is reporting, not a gate: the
`Code Check` job already fails the pull request on anything the first four
report, so the job is not a required check and nothing depends on it.

What it adds is history. Code scanning deduplicates a finding across runs,
tracks when it appeared and when it went away, and lets one be dismissed with a
reason that sticks, none of which a job log does. Checks skipped inline with
`#checkov:skip=` arrive carrying SARIF `suppressions` and show as dismissed
rather than open.

zizmor runs only there and gates nothing. It audits the workflows themselves
for template injection, credential persistence and overly broad permissions.
Its current findings are hardening opportunities rather than defects, and some
need a policy decision (pinning actions to a hash rather than a tag), so they
are reported without blocking a merge.

Pull requests from forks skip the job. A fork's token cannot write
`security-events`, and their findings still block the merge through `Code
Check`.

### Why the custom rules exist

The default gitleaks ruleset targets provider-issued tokens (AWS keys, GitHub
PATs, PEM blocks). Its one generic rule, `generic-api-key`, requires entropy
>= 3.5 and accepts only `[0-9a-z-_.=]` in the value. Measured against the nine
credential shapes found in this repo's own config files, it caught five. The
four custom rules in `.gitleaks.toml` cover the rest: 32-hex API keys just below
the entropy threshold, passwords containing symbols, credentials held in XML
elements, and Bazarr's raw provider session cookies.

Two other scanners were measured on the same nine shapes and are not a
substitute. Trivy (already enabled) detects AWS keys, GitHub PATs and PEM
private keys, but none of the nine. TruffleHog and Secretlint detect none of
them either, being oriented at verifying provider credentials.

`.gitleaksignore` records findings that exist only in already-published history
on `main`. It stores `commit:path:rule:line` fingerprints, never secret values.
Those credentials cannot be fixed by editing the working tree and removing them
would mean rewriting published history, so they are rotated instead.

One trap worth knowing: a path allowlist pattern containing `$` inside an
alternation, such as `\.env($|\.)`, silently matches nothing. Write the
prefix form instead. A trailing `$` outside a group behaves normally.

To audit a branch by hand:

```shell
gitleaks git . --redact -c .gitleaks.toml --log-opts="main..HEAD"
```

### Live application state

Runtime databases, and configs an app rewrites on shutdown, must never be
tracked. `tests/test_prerequisites.py` asserts this per path, so a reintroduced
`.gitignore` negation fails the test suite rather than reaching a commit. When
an app config needs a committed seed, track a sanitized `<file>.example` and let
`scripts/seed-configs.sh` copy it into place on `make bootstrap`; the same test
file asserts every seeded path has a tracked `.example`.

## Unattended dependency updates

Patch, minor and digest bumps from Renovate merge with nobody reviewing them.
[docs/CONTRIBUTING.md](CONTRIBUTING.md) step 8 has the mechanics; this is the
risk that buys and what is placed against it.

The exposure is a malicious upstream release reaching `main` on its own, and
being run by the integration suite on a runner that has just authenticated to
Docker Hub. It is not a new exposure, since the suite already ran that code the
moment a maintainer typed `/run-tests`; what automation removes is the pause
where a person might have noticed. The blast radius is bounded by there being
exactly two secrets in this repository, `DOCKERHUB_USERNAME` and
`DOCKERHUB_TOKEN`, and no deployment credentials of any kind.

**The scanners do not cover this, and it is worth being exact about why.** The
`Security Reports` job runs Trivy as `fs --scanners vuln,misconfig` against the
working tree, so it reads the manifests that name an image and never pulls or
inspects the image itself. checkov reads infrastructure configuration, gitleaks
reads for credentials, hadolint reads two Dockerfiles. Only zizmor would see a
malicious change here, and only if it were made to a workflow file. Beyond that,
all of them match published advisories, and a supply chain attack on the day it
lands has none: there is no CVE for a package that was backdoored an hour ago.
Adding image scanning would raise the floor on known vulnerabilities without
changing this.

What is placed against it instead:

- **A seven day cooling window** (`minimumReleaseAge` in
  `.github/renovate.json5`). Compromised releases are typically found and pulled
  within hours to days, so the window converts "merged it first" into "it was
  yanked before we saw it". Seven rather than fourteen because this stack faces
  the internet and being a fortnight behind on ordinary fixes is its own risk.
  `vulnerabilityAlerts` clears the window, so a fix for a known vulnerability is
  never held back by it.
- **Digest pinning** (`pinDigests`). Every image that names a version is pinned
  to its manifest-list digest, so a republished tag cannot change what runs
  without a pull request saying so.
- **A pin-only diff assertion** (`scripts/assert-pin-only-diff.py`). Its verdict
  is published as the `Pin Only` commit status by
  `.github/workflows/coderabbit-gate.yml`, and both `bot-auto-merge.yml`'s
  approval and the `Review Verified` status below read that published result
  rather than each running the script again. The approval is withheld unless
  every changed line differs in nothing but a version or a digest *in a pin
  position*, across five allowed files. The qualifier is the point: a number
  that is not a pin is not substitutable, so `PUID=1000` becoming `PUID=0`,
  which would run every container as root, is refused like any other
  structural change. This is aimed at the bot identity rather than the
  upstream: without it, approving on the strength of the author means a
  compromised Renovate could rewrite a workflow and be approved for it, and two
  of those five paths execute what they contain.
- **CodeRabbit as the reader, gated by `Review Verified` rather than by
  `CodeRabbit` itself** (#114). A pin-only diff passes unattended since
  CodeRabbit never reviews a bot's pull request at all (#113); anything that
  reaches outside that lane is graded like a human pull request instead. Its
  reach is genuinely narrow either way: a version bump has no reviewable
  content, so it cannot detect a backdoored image, and it covers the same case
  the assertion above does, a change to logic carried alongside a bump. Its
  comments still arrive as unresolved conversations, which branch protection
  blocks on regardless of either status, and `request_changes_workflow` stays
  off for the reason recorded in `.coderabbit.yaml`. See
  [docs/MERGE_PIPELINE.md](MERGE_PIPELINE.md) for the three lanes
  `Review Verified` actually grades and why a green `CodeRabbit` check was not
  evidence of a review in the first place.
- **The suite itself**, which has to pass on the pull request's own head
  before it merges. See [docs/MERGE_PIPELINE.md](MERGE_PIPELINE.md) for the
  merge queue, which now runs every required context a second time against
  its own throwaway commit before anything merges.

What remains, and is accepted: the two bot identities are trusted to be
themselves, and an upstream release that survives seven days, produces a
pin-only diff, and passes the suite will merge. There is no configuration that
removes that; only reviewing every dependency bump by hand would, at the cost of
the bumps not happening.

## Verification

```bash
# Confirm app processes run as non-root
for c in sonarr radarr bazarr lidarr prowlarr readarr whisparr qbittorrent sabnzbd jellyfin prometheus grafana; do
  echo -n "$c: "; podman exec $c id 2>/dev/null || echo "not running"
done

# Confirm security options and capability drops
podman inspect sonarr --format 'SecurityOpt={{.HostConfig.SecurityOpt}} CapDrop={{.HostConfig.CapDrop}}'

# Run just the security-marked tests. `make test` is now three separate
# pytest invocations, each with its own -m filter (see the Makefile), and
# pytest's -m flag is single-value, so PYTEST_ARGS="-m security" would
# override each tier's filter rather than combine with it, running the same
# security tests three times over. Invoke pytest directly instead:
tests/.venv/bin/pytest -m security
```

---

See also: [README.md](../README.md), [docs/MERGE_PIPELINE.md](MERGE_PIPELINE.md),
[docs/MAKE_COMMANDS.md](MAKE_COMMANDS.md)
