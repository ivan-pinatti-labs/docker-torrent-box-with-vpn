# Dependency Updates

Renovate opens every routine dependency pull request here. Dependabot did too, until its
`updates:` config was removed from `.github/dependabot.yml` on 2026-09-07; see "Retiring
Dependabot" below for the migration itself, and "The one setting that did not move with the
file" for the one way Dependabot can still open one, until a maintainer clears it. This page is
the reference for what runs when and why the schedule is shaped the way it is. The mechanics of
how a bump actually merges live in [docs/MERGE_PIPELINE.md](MERGE_PIPELINE.md); this page does
not repeat them.

## Which manager owns what

Every ecosystem is Renovate's now, split between its native managers, which read a manifest
file directly, and its `customManagers`, regex based and reserved for pins that have no
manifest of their own.

| Ecosystem | Manager | Where the pin lives |
| --- | --- | --- |
| pre-commit hook revisions | native, `pre-commit` | `.pre-commit-config.yaml`, the `rev:` of each hook repo |
| GitHub Actions | native, `github-actions` | Workflow `uses:` versions under `.github/workflows/` |
| pip, test suite | native, `pip_requirements` | `tests/requirements.txt` |
| Docker image versions | custom | `.env.example`, behind a `# renovate: depName=...` annotation |
| pip, inline in a workflow | custom | A `pip install pkg==x` line, behind a `# renovate:` annotation |
| Go module and pypi pins in pre-commit | custom | `additional_dependencies` in `.pre-commit-config.yaml` |
| Docker images pinned inside a hook `entry:` | custom | `.pre-commit-config.yaml` and the workflow SARIF job |

The first three used to be Dependabot's, reading the same three files it did; only the tool
reading them changed; see "Retiring Dependabot" below. `pre-commit` is Renovate's own name for
its native manager and ships disabled upstream ("not supported by the pre-commit maintainers or
community" per its own warning, a statement about where bug reports go rather than a reason to
leave hook revisions unwatched), switched on in `.github/renovate.json5`.

The last four stay `customManagers` because none of them has a manifest file a native manager
could read: a bare regex is what covers an annotation sitting in the middle of a line other
tooling owns, whether that line is `.env.example`, a workflow's `run:` step, or a pre-commit
hook's `entry:`. The split is now entirely about manifest versus inline pin, not about which
bot is reading which half. It exists because Renovate's own `pip_requirements` manager only
reads requirements files. It would never see `pip install podman-compose==1.6.0` sitting inside
a workflow's `run:` step, so a pin left unwatched there rots silently, which is exactly how CI
once ended up installing whatever version of `podman-compose` happened to be current. The
`# renovate:` annotations are the seam that covers those inline pins, and the reasoning is
spelled out in the header comment of
[`.github/renovate.json5`](../.github/renovate.json5); this page reuses that reasoning rather
than restating it differently.

The native `pre-commit` manager reads more than `rev:`, and that turned out to matter. Its
extractor walks every hook in the file, `repo: local` included, and additionally parses
`additional_dependencies` wherever a hook declares `language: golang`, `python` or `node`,
which describes exactly two hooks here: `gitleaks-history` (`language: golang`) and `checkov`
(`language: python`). Both are already read by the `additional_dependencies` customManager
above, by annotation. Confirmed live with `npx renovate --platform=local --dry-run=lookup`:
before a fix, the native manager independently proposed the identical `github.com/zricethezav/gitleaks/v8`
and `checkov` updates the customManager already covers, which is two managers able to open
competing pull requests for the same line. A `packageRules` entry in `.github/renovate.json5`
disables the native manager's output for the `pre-commit-golang`, `pre-commit-python` and
`pre-commit-node` depTypes specifically, confirmed by the same dry run to leave both
dependencies `skipReason: disabled` there while the customManager keeps proposing them
normally. The native manager's `rev:` extraction, which carries the plain `repository` depType,
is untouched by that rule.

## The daily layout

| When | What opens |
| --- | --- |
| Daily, before 07:00 | Every Renovate update: the grouped and ungrouped images, the pre-commit hook revisions, GitHub Actions, `tests/requirements.txt`, and the inline pip and Go/PyPI pins |

One schedule for everything now. Until 2026-09-07, Dependabot ran the three ecosystems it
managed at 06:00, 06:30 and 07:00 respectively, staggered so the suites this repository
triggers did not all start in the same few minutes; see "Retiring Dependabot" below for why
they moved onto Renovate's own schedule instead of keeping separate slots of their own. There
is no fixed weekday to check either. Dependabot ran Thursday and Friday until 2026-09-02, out
of an organization-wide slot table that has since been deleted; see "Why Renovate is not
staggered" below.

## Why Renovate is not staggered

It used to be. The groups above opened on separate weekdays, and the reason
was `strict` required status checks on `main`: every merge put every other
open pull request behind, so each needed a rebase and another full run of the
integration suite, roughly fifteen minutes a time. Issue #117 records a single
small change that needed three separate suite runs for this. Spreading the
groups across the week was what kept that from compounding into one bad day.

`main` is now behind a merge queue and `strict` is off, so a merge no longer
invalidates anything. The queue builds each entry against the current `main`
itself. With the cascade gone, the stagger was buying nothing and still
costing: a weekly window stacks on top of `minimumReleaseAge`'s seven days
rather than overlapping it, so a release that missed its day by a day waited a
full extra week. The seven-day minimum was unchanged; what grew was the
worst case, to roughly 14 days.

Renovate now runs daily, matching every other repository in the organization.
Pull request volume is bounded by `prConcurrentLimit` and `prHourlyLimit`
instead of by the calendar; those are the levers if it ever needs bounding
again. Reinstating a weekday spread would bring the 14 day floor back with it.

Dependabot kept its weekday slots for a while longer, on the grounds that
those were a different concern: they existed so two repositories' bots would
not open pull requests in the same hour and queue their CodeRabbit review
requests behind each other.

That turned out not to be a concern either. A pin-only bump from *either* bot
resolves `Review Verified` through `coderabbit-review-verdict.py`'s bot lane
with CodeRabbit never asked, so Dependabot spent no review quota and had
nothing to queue behind. Confirmed on this repository's own merged pull
requests: #139 and #140 are Dependabot and report `pin-only diff, nothing to
review`, identical to Renovate's #135, #136 and #138. The weekday table was
deleted on 2026-09-02 and Dependabot moved to daily here and everywhere else.

The same 14 day arithmetic applied to it the whole time, and that is the part
worth remembering: a weekly slot stacked on `cooldown`'s seven days rather
than overlapping them, so a release missing its day by a day waited a full
extra week. The organization policy now lives in
`ivan-pinatti-labs/.github`'s `README.md` under "Dependency policy".

## Retiring Dependabot

Dependabot's `updates:` config came out of `.github/dependabot.yml` on
2026-09-07, five days after it last moved (see "Why Renovate is not
staggered" above), leaving Renovate as the only bot that opens a routine
dependency pull request here (see "The one setting that did not move with
the file" below for the one path this did not close). The three ecosystems
it managed, pre-commit hook revisions, GitHub Actions and
`tests/requirements.txt`, moved to Renovate's own native managers for the
same files rather than to a fourth
`customManagers` entry: `pre-commit`, `github-actions` and `pip_requirements`
each already read the exact field Dependabot did, so nothing needed
inventing, only switching on. `pre-commit` is the one of the three that ships
disabled upstream and needed a line in `.github/renovate.json5`; the other
two were already enabled by default; see "Which manager owns what" above.

One thing did not change as a side effect of this, deliberately: grouping.
Each ecosystem still opens as one pull request rather than one per
dependency, the same shape `dependabot.yml`'s own `patterns: ["*"]` groups
gave it, now written as a `packageRules` entry matching the manager instead.

Security coverage is a different case, worth being careful about rather than
assuming: `updates:` coming out of `dependabot.yml` only ever governed
Dependabot's routine version updates, the three ecosystems above. It never
governed Dependabot's own alert driven security updates for GitHub Actions
and pip, which read the dependency graph directly and are switched by a
separate GitHub repository setting untouched by this file. See "Security
updates" below for what does and does not change there, including a setting
that turned out not to move with the rest.

What did change, because the old split stopped applying to it: the
`ALLOWED_PATHS` pin files in `scripts/assert-pin-only-diff.py`, the bot
identity checks in `.github/workflows/bot-auto-merge.yml`,
`coderabbit-gate.yml` and `integration-tests.yml`, and the `BOTS` set in
`scripts/coderabbit-review-verdict.py` all named `dependabot[bot]` alongside
`renovate[bot]`. Every one of those checks now names `renovate[bot]` only;
none of the files it checks changed, since Renovate's native managers for the
three retired ecosystems write into the same paths Dependabot did.
`.github/dependabot.yml` itself was deleted rather than left as an empty
shell: nothing left in it after `updates:` comes out is something that file
configures; see "Security updates" below for the one GitHub setting worth
being careful about here.

## The grouping rationale

Grouping in `.github/renovate.json5` is about pull request volume against blast radius, not a
shared release cadence, and it is worth being explicit that the cadence framing would be
fiction. Image creation dates measured with `skopeo inspect` on 2026-08-18:

| Image | Build date |
| --- | --- |
| nzbget | 2025-05-09 |
| readarr | 2025-06-27 |
| gluetun | 2026-02-11 |
| qbittorrent | 2026-05-03 |
| jellyfin | 2026-06-02 |
| bazarr | 2026-06-30 |
| radarr | 2026-08-02 |
| calibre-web | 2026-08-02 |
| loki | 2026-08-05 |
| prowlarr | 2026-08-05 |
| sabnzbd | 2026-08-06 |
| sonarr | 2026-08-07 |
| lidarr | 2026-08-12 |

Fifteen months separate the oldest and newest build in that list, so nothing here releases on a
shared schedule. The arr suite, the observability stack, and the library and reading tools are
grouped anyway, purely to keep the number of pull requests down, and grouping only makes sense
where a bad member costs little: those three groups hold images that have not caused a problem
recently, or, for the observability stack, sit behind a profile that is disabled by default.

The observability stack went from three images to eleven when the exporters were annotated, and
the integration suite does exercise all of them. That was not true at first: CI applied one
variable out of `.env.tests` by hand and left the rest, so those profiles stayed disabled there
and every test carrying the `observability` marker skipped. CI now applies the whole file through
`make enable_test_profiles`, so the images are pulled, the containers started, and the tests run.
That is what lets the group merge unattended and stay defensible rather than merely cheap: the
argument before it was only that the profile ships disabled, so a bad image there breaks nothing
until someone turns it on.

`docker.io/library/alpine`, which `log_rotator` runs, is the one observability image left out of
that group. `LOG_ROTATOR_PROFILE` ships enabled, so it was the only one CI pulled and started
before the rest were covered at all, and keeping it on its own schedule costs nothing now that
they are.

The download clients (qbittorrent, sabnzbd, nzbget, nzbhydra2, jdownloader-2), jellyfin,
homepage, flaresolverr, wireguard, and gluetun are deliberately left out of every group, so each
arrives as its own pull request on the Saturday default instead. sabnzbd and jdownloader-2 arrive
with nothing at all while the hold described under "Images pinned to a patch" stands; the
isolation still describes where they land the day it is lifted. A group is only as mergeable as
its worst member, and this week supplied two examples, both download clients: SABnzbd 5.0.4
rewrote its own bind address in a way that broke a test (see issue #108), and qBittorrent
5.2.2 changed its login response to `204 No Content`, which is still holding pull request #83.
Had either of those shipped inside a group, it would have blocked every other image bundled with
it rather than only itself. gluetun is isolated for the same reason: it is what the download
clients' kill switch depends on, so a bad gluetun bump is exactly the kind of failure a group
should not be allowed to spread.

nzbget no longer arrives as a pull request at all, isolated or otherwise. It is not part of the
default stack (`NZBGET_PROFILE=disabled`; SABnzbd is the usenet client actually enabled), and
`.env.tests` does not turn it on either, so no test in this repository ever starts an nzbget
container. A version bump there could never be validated by CI, only by everything else in the
suite continuing to pass, which is exactly the gap PR #103 (`24.8.20250509 -> 26.2.20260821`)
exposed: the bump itself was verified genuine by hand, and was closed rather than merged because
maintaining a pin CI cannot check is a liability, not coverage. `.github/renovate.json5` now holds
`docker.io/linuxserver/nzbget` with `enabled: false`. Dropping that rule is a decision to actually
run and test nzbget again, not merely to bump its pin.

Two more pins carry an `allowedVersions` ceiling rather than being grouped or held, because their
tag history contains something that outranks their real version line under Renovate's default
docker versioning: `docker.io/linuxserver/qbittorrent` (`<10.0.0`) and
`docker.io/linuxserver/readarr` (`<1.0.0`). The qbittorrent case is what PR #137 exploited --
`5.2.2 -> 20.04.1`, a four-and-a-half-year-old image from an abandoned Ubuntu-base-release tag
line that satisfied the entire integration suite anyway -- and readarr's `1.0.<build>` decoy tags
(123 of them, all built around 2021-12, really an early `0.1.0` build under `versioning=loose`)
were found by auditing every LinuxServer pin for the same shape afterward. See the comment above
each rule in `.github/renovate.json5` for the full evidence, and
[`tests/test_version_pins.py`](../tests/test_version_pins.py) for the coverage that asks each
running service what version it actually is, which is the check that would have caught PR #137
directly instead of relying on a human noticing an implausible major-version jump.

Four more pins are ungrouped without that argument applying to them, simply because there is no
group they belong in: `docker.io/library/alpine` for the reason above,
`docker.io/linuxserver/mylar3` because it is the base of a wrapper this repository builds rather
than an image it pulls, `ghcr.io/notifiarr/notifiarr` because its service is commented out, and
`docker.io/linuxserver/jackett` because it has no service at all. The last two are watched
anyway. An unwatched pin is the thing this arrangement exists to prevent, and a year stale image
is a worse starting point than a current one for whoever turns either service back on.

## Why tests/requirements.txt is pinned exactly

Every entry is `==`, not `>=`, and the difference mattered in two ways that
were both invisible until #94 sat unapproved, back when Dependabot managed
this file.

**The cooling window did not reach this surface.** `make bootstrap_tests`
builds `tests/.venv` from scratch and runs `pip install -r
tests/requirements.txt`, so a `>=` floor resolved to whatever was newest on
PyPI at that moment. Neither bot's cooldown governs what pip installs, only
when it *proposes* a change, so a package published an hour earlier went into
the suite on the next run regardless of which bot's schedule that was. This
reason is not bot specific and did not go away with Dependabot: it is why
these pins stay exact under Renovate's `pip_requirements` manager too.

**The update-type grader could not read a floor bump**, and this half was
specific to the tool that has since left. `bot-auto-merge.yml` used to approve
a Dependabot bump only when every entry in `updated-dependencies-json` was a
patch or minor, and `fetch-metadata` could not compute an update type without
an exact prior version to compare against; it returned an empty string, the
grader could not grade that, and withheld approval by design, so the pull
request stayed green but unapproved. That is the whole story of #94. Renovate
never had this problem: it reads the previous pin straight out of the file
itself rather than through a marketplace action, so it can classify an update
from a `>=` floor exactly as well as from an exact pin. The grader this
reasoning was about is gone from `bot-auto-merge.yml` along with Dependabot
(see "Retiring Dependabot" above), so nothing here argues for loosening the
pins now; the first reason above still does.

Pinning fixed both without changing a single installed version: the pins are
what `>=` was already resolving to. Renovate maintains them from here, under
the cooldown, and `Tests Verified` is what clears them.

## Security updates

Renovate's `vulnerabilityAlerts` setting is the alert driven remediation path this repository's
own merge pipeline is built around, and it reads none of the schedules above: it clears the
inherited `minimumReleaseAge` window entirely, so a fix for a known vulnerability is never held
back by the cooling period described below.

That was already true before Dependabot's version updates were retired, not something this
migration added. `vulnerabilityAlerts` is unscoped by datasource, so it covered GitHub Actions
and pip the whole time the two bots ran side by side, alongside Dependabot's own security
updates for the same two ecosystems, which opened independently as soon as GitHub raised an
alert. Retiring Dependabot's version updates did not retire that second, independent path:
Dependabot's own security updates are a separate GitHub setting, `automated-security-fixes`,
untouched by removing `dependabot.yml`'s `updates:` block and still live as of this writing.
See "The one setting that did not move with the file" below for exactly what that means and
what closes it. Nothing here is stated as fully "only Renovate" until that setting is disabled.

That coverage has a real gap, and it is worth stating plainly rather than leaving it implicit.
The dependency graph GitHub builds for this repository holds 17 packages, all GitHub Actions and
pip, and zero container images: GitHub raises no vulnerability alert for a container image at
all, so the images in `.env.example` get no security signal from this mechanism, ever, and never
did. Scanning the images themselves was considered and deliberately declined, because they are
third party and not ours to patch: nothing here can fix a vulnerability inside a published
image, only wait for upstream to. The practical consequence is that the seven day
`minimumReleaseAge` window in `.github/renovate.json5` is pure latency for every image bump,
with nothing available to bypass it the way `vulnerabilityAlerts` bypasses it for Actions and
pip. That is a conscious trade, not a hedge: see [docs/HARDENING.md](HARDENING.md) for the full
reasoning behind leaning on the cooling window instead of a scanner for this class of
dependency. This gap is pre-existing and unrelated to Dependabot's retirement: no container
image ever had a vulnerability-alert-driven path, from either bot, so there is nothing this
migration could have narrowed there.

GitHub's Dependabot Alerts and the dependency graph itself are what raises the alert
`vulnerabilityAlerts` reads. Both are repository settings under Settings, not something either
bot's config file turns on, and neither is touched by removing `dependabot.yml`'s `updates:`
block: they stay enabled, and should.

### The one setting that did not move with the file

Removing `.github/dependabot.yml`'s `updates:` block does not, by itself, stop Dependabot from
opening a security pull request. GitHub's automated security fixes (Dependabot security
updates, the actual pull request half, as distinct from the Dependabot Alerts that merely
raise a signal) are governed by a separate repository setting,
`automated-security-fixes`, that reacts to an alert on its own and does not read
`dependabot.yml` to decide whether to act. Verified live against this repository with
`gh api repos/<owner>/<repo>/automated-security-fixes`: it reports `{"enabled": true,
"paused": false}`, unchanged by this migration, since nothing in a pull request's file diff
can touch it.

Left as it is, this is a real gap in "Renovate opens every routine dependency pull request
here": a security alert could still make Dependabot open one, on a login this repository's
tooling no longer recognizes. Concretely, `bot-auto-merge.yml` would supply it no
approval (only `renovate[bot]` reaches that path now), and `coderabbit-review-verdict.py` would
grade it in the human lane rather than the unattended bot lane, so it could not merge on its
own; but it would still sit open needing a maintainer to close it, which is exactly the
orphaned-bot-pull-request shape this migration exists to remove. This is deliberately left as a
manual action rather than something this pull request's diff changes: disabling
`automated-security-fixes` is a live repository setting change with no file to review it
through, not a version-controlled edit, and turning off a security remediation path is a
decision for a maintainer to make deliberately rather than a side effect of a dependency bot
migration. **Disable "Dependabot security updates" (`automated-security-fixes`) for this
repository in Settings, leaving Dependabot Alerts and the dependency graph enabled.**

## What was frozen, and for how long

Twelve image pins carried no `# renovate:` annotation, so Renovate could not see them and they
sat at whatever version was committed. Their build dates, measured with `skopeo inspect` on
2026-08-20 alongside the newest tag available on the same day:

| Pin | Image | Pinned build | Newest available |
| --- | --- | --- | --- |
| `QBITTORRENT_EXPORTER_VERSION` | `ghcr.io/esanchezm/prometheus-qbittorrent-exporter` | 2024-10-25 | `v1.7.0` |
| `NGINX_EXPORTER_VERSION` | `docker.io/nginx/nginx-prometheus-exporter` | 2024-12-04 | `1.5.3` |
| `CADVISOR_VERSION` | `gcr.io/cadvisor/cadvisor` | 2025-03-20 | `v0.55.1` |
| `SABNZBD_EXPORTER_VERSION` | `docker.io/msroest/sabnzbd_exporter` | 2025-11-07 | already current |
| `PODMAN_EXPORTER_VERSION` | `quay.io/navidys/prometheus-podman-exporter` | 2025-12-22 | `v1.21.2` |
| `NODE_EXPORTER_VERSION` | `docker.io/prom/node-exporter` | 2026-04-07 | `v1.12.1` |
| `PODMAN_LIMITS_EXPORTER_VERSION` | `docker.io/library/python` | 2026-04-17 | `3.14-alpine3.22` |
| `ALLOY_VERSION` | `docker.io/grafana/alloy` | 2026-04-23 | `v1.18.1` |
| `JACKETT_VERSION` | `docker.io/linuxserver/jackett` | 2026-04-23 | `0.24.2424` |
| `MYLAR_VERSION` | `docker.io/linuxserver/mylar3` | 2026-05-01 | `v0.11.0-ls268` |
| `LOG_ROTATOR_VERSION` | `docker.io/library/alpine` | 2026-06-22 | `3.24` |
| `NOTIFIARR_VERSION` | `ghcr.io/notifiarr/notifiarr` | the tag did not exist | `v0.9.5` |

The three oldest are between 17 and 22 months behind. All twelve are annotated now, and
`tests/test_renovate_pins.py` fails the suite if a pin is ever added without an annotation
again.

`NOTIFIARR_VERSION` deserves its own line, because the pin was not merely stale. It read
`v0.9.5-alpine`, and that tag does not exist: Notifiarr stopped publishing the `-alpine`
variant after `v0.9.1-alpine` when Alpine became the default flavour, so the plain
`v0.9.5` tag is the same image. Nothing noticed because the `notifiarr` service block is commented
out in `docker-compose-servarr.yml`, so nothing ever tried to pull it. `docker` versioning would
also have refused to update it forever, since the compatibility suffix `alpine` has to match
exactly and no `-alpine` tag above `0.9.1` exists.

`KORSYNC_VERSION` was a thirteenth case, and the one worth understanding, because it looked
watched. Its annotation read `# renovate: datasource=docker depName=...`, and the custom manager
in `.github/renovate.json5` matches `# renovate: depName=` only, so that one extra word made the
whole pin invisible while reading exactly like every other line in the file. `datasource` was
redundant anyway, because the manager sets `datasourceTemplate: "docker"` for every pin it reads.
That is the case the new test's fourth check exists for: it runs the manager's own regex against
`.env.example` and fails when the annotations present in the file and the ones Renovate can
actually parse are not the same set.

## Images held at a fixed version

Four containers run a file bind mounted out of `patches/`: sabnzbd, lazylibrarian, mylar, and
jdownloader-2. Their images are held at a fixed version in `.github/renovate.json5`, with
`enabled: false`, until the patch that made each one special is gone.

The reason is that a patch shadows one file inside an image, and nothing in this repository can
tell whether the shadowing copy still matches the file it replaces. An unattended bump pairs
patched old source with new upstream code, and the result starts, reports healthy, and passes the
suite while being subtly wrong. mylar shows the scale of it: its first offered bump is
`v0.9.0-ls252` to `v0.11.0-ls268`, which `loose` versioning calls a minor because both share
major `0`, so it would have merged unattended across two upstream minor releases with five
patched files mounted over it. The alternative to holding the pin is re-deriving each patch
against each release, which is work with no end date and no test that would catch getting it
wrong.

The hold covers digest refreshes too, not only version bumps. `patches/sabnzbd/svc-sabnzbd/run`
shadows a file belonging to the image rather than to the application, an s6 service script, and a
rebuild of the same tag is exactly how that changes underneath the patch.

Two of the four patches are gone as of 2026-09-02, both because the fix reached the image.
`patches/jdownloader2/` went when `baseimage-gui` 4.13.0 gave the secrets loader a `force`
argument, which the pinned image already carried (#107), and `patches/lazylibrarian/` went when
upstream !1832 reached the image, which needed a pin bump to collect (#109). jdownloader-2 came
off the hold with its patch; lazylibrarian did not, for the reason under "Remaining gaps" below.

Worth being explicit about the cost: sabnzbd and jdownloader-2 were both flowing, and merging
unattended, before this. It costs less than it looks like, because, as the section above says,
GitHub raises no vulnerability alert for a container image at all, so neither pin had a security
path that this closes. What is given up is routine version updates on two download clients, and a deliberate
hand bump is what replaces them.

`docker.io/library/python` was held here too and is not any more, and the reason it was is worth
keeping because it says what the coverage had to be worth. It is one of two pins where the image
is not the application: `podman_limits_exporter` runs a bare interpreter over
`scripts/podman-limits-exporter.py`, this repository's own code, bind mounted in as
`/exporter.py`, so a Python minor bump swaps the interpreter out from under code written here
rather than shipping a new version of somebody else's program. Nothing tested that, so the pin
waited for a person.

Reachability alone would not have been enough to release it. The container's healthcheck is
`wget -q -O /dev/null .../metrics`, which discards the body, and a Prometheus scrape target counts
as up on an empty but parseable response, so neither notices an interpreter change that leaves the
script serving 200 and producing nothing. `tests/test_observability.py` therefore asserts three
things: that both series reach Prometheus, that at least one CPU limit is above zero, since zero
is the exporter's own value for "unlimited" and an all-zeros regression is otherwise
indistinguishable from a real reading, and that the exporter's own limit matches what
`TELEMETRY_CPUS` asked compose for, which walks `.env` to compose to the podman API to Prometheus
rather than checking that bytes came back.

One limit remains and is not a bug: `3.13-alpine3.22` only moves in one dimension, because
`docker` versioning requires the compatibility suffix to match exactly, so Renovate can offer
`3.14-alpine3.22` and will never offer `3.13-alpine3.24`, which exists.

`docker.io/library/alpine` has the same shape and is deliberately left flowing. `log_rotator` runs
`scripts/rotate-nginx-logs.sh` over a bare Alpine image, so that is our code too, but
`LOG_ROTATOR_PROFILE` ships enabled so CI does pull and start it, and a shell script against a new
BusyBox is a far smaller surface than our Python against a new interpreter.

`tests/test_renovate_pins.py` closes the loop in the other direction: it derives the patched set
from the `./patches/` volumes in the compose files rather than from a list, so a service that
grows a patch mount whose image is not held fails the suite. Each remaining patch has an open
issue for dropping it (#106 mylar, #108 sabnzbd), and dropping one is what unfreezes its pin, as
issues #107 and #109 already showed. That is the distinction this whole page turns on: these
pins are deliberately fixed, not accidentally frozen.

## Remaining gaps

Three tags are deliberately left floating rather than pinned to a version at all:
`NGINX_VERSION=stable-alpine`, `PLEX_VERSION=latest`, and `WHISPARR_VERSION=v3`.
`tests/test_renovate_pins.py` carries them in an explicit allowlist, so the exemption is a
decision on the record rather than an omission.

`MYLAR_VERSION` carries no digest, and cannot as it stands. It is read twice out of one
variable: as the base image the wrapper in `build/` is built on, and as the tag of the locally
built result. A digest is legal in the first position and not in the second, because an image
being built can only be given a tag, so `pinDigests` is turned off for it in
`.github/renovate.json5` and the test exempts it by name. An earlier note recorded this the
other way round, asking for a digest to be added; adding one would have stopped the wrapper
building.

`LAZYLIBRARIAN_VERSION` was the other half of that pair until 2026-09-03, and it is the worked
example of the way out. The wrapper's own image is now tagged `local` rather than with the
version, which leaves the variable naming only the base, which can then carry a digest. **The
same fix applies to mylar** whenever its patch clears and there is reason to touch that file;
issue #106 records it.

Splitting it also settled issue #119, which was the harder half. The tag is a composite:
`82aad29e-ls342` is the upstream LazyLibrarian commit and linuxserver's own build revision,
joined by a hyphen. Neither half orders the tags on its own. The hex is a commit, and the `ls`
number only moves when linuxserver's side changes, so two releases can share one: `ls342` was
published twice, on 2026-09-02 and 2026-09-03, with different app commits. `ls314` appears four
times in the last hundred releases. LazyLibrarian publishes no versions upstream at all, which
is why linuxserver has none to put in a tag, and why `mylar3` gets `v0.9.0-lsNNN` and this image
does not.

So it is not ordered. `LAZYLIBRARIAN_VERSION=latest@sha256:...` tracks the tag linuxserver
actually documents, and Renovate refreshes the digest as it moves. There is no ranking to get
wrong, the pin is still immutable because the digest decides what runs, and the automerge rule
already covers `digest` updates.

`KORSYNC_VERSION` used to be the other case, pinned to `sha-7bcefd34...`, a commit tag nothing can
order. Upstream publishes plain semantic tags and has since well before that pin landed here on
2026-07-03, so the commit tag was never necessary. It now reads `0.2.3`, which is both a move
forward, since the release is dated 2026-07-15 against the pinned build's 2026-04-29, and a tag
Renovate can maintain by itself. `0.2.3`, `0.2` and `latest` all resolve to the same digest.

The distinction that matters is that a pin with no annotation is invisible, while a pin that
cannot be ordered is visible and merely stuck: Renovate looks it up every run, and the dependency
dashboard is where a lookup that resolves to nothing shows up.

---

See also: [README.md](../README.md), [docs/HARDENING.md](HARDENING.md),
[docs/CONTRIBUTING.md](CONTRIBUTING.md), [docs/TESTING.md](TESTING.md)
