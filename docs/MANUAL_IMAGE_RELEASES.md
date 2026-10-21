# Manual Image Releases

The runbook for the images Renovate cannot update on its own. Renovate holds every update for
seven days (`minimumReleaseAge`) and reads the date it counts from on Docker Hub alone, so an
image from any other registry is held indefinitely. Each of those updates is released by hand,
after checking the date the registry itself recorded, by following this page. Why it works this
way, and which images moved to Docker Hub to avoid it, is in
[docs/DEPENDENCY_UPDATES.md](DEPENDENCY_UPDATES.md), "Images outside Docker Hub". Issue #321
tracks the Renovate changes that would retire this page.

## When to run it

Nothing runs it on a schedule. A maintainer asks an agent to, roughly monthly, and sooner when a
held image carries a fix the stack needs. A run that releases nothing is still worth a line in
the [release log](#release-log) when it found something worth knowing, such as a build that
becomes eligible on a given day.

## Held images

| Pin | Image | Where the push date is recorded | Notes |
| --- | --- | --- | --- |
| `WHISPARR_VERSION` | `ghcr.io/hotio/whisparr` | [GHCR package page](https://github.com/users/hotio/packages/container/package/whisparr) | hotio rebuilds `v3` every few days, so release [one build back](#one-build-back). Pinned as `v3@<digest>`; Renovate cannot order hotio's release tags |
| `KORSYNC_VERSION` | `ghcr.io/nperez0111/koreader-sync` | [GHCR package page](https://github.com/users/nperez0111/packages/container/package/koreader-sync) | GHCR only |
| `QBITTORRENT_EXPORTER_VERSION` | `ghcr.io/esanchezm/prometheus-qbittorrent-exporter` | [GHCR package page](https://github.com/users/esanchezm/packages/container/package/prometheus-qbittorrent-exporter) | also on Docker Hub, but as a separate build, so it stays on GHCR |
| `PODMAN_EXPORTER_VERSION` | `quay.io/navidys/prometheus-podman-exporter` | [quay.io tag API](#quayio) | quay.io only. A major (`v2`) is also offered; that one needs a person regardless |
| `CADVISOR_VERSION` | `gcr.io/cadvisor/cadvisor` | [gcr.io tag list](#gcrio) | Docker Hub's `google/cadvisor` stopped at `v0.33.0` |

`tests/test_renovate_pins.py` fails the suite when an image pin names a registry other than
Docker Hub and the image is missing from this table, so a new one cannot freeze silently, and
when this table and the images left out of Renovate's automerge rule (step 4 below) differ.
The organization's own images (`ghcr.io/ivan-pinatti-labs/**`) are not here:
`.github/renovate.json5` gives them `timestamp-optional`, for the reasons written beside that
rule.

## Releasing an update

1. **List what is held.** Read the Dependency Dashboard (#24), section "Pending Status Checks".
   Entries for the images in the table above are the ones held for lack of a date, each with the
   version and digest Renovate would move to. A Docker Hub entry there is simply still inside its
   seven days; leave it alone.
2. **Find the date the registry recorded** for each held image's exact version and digest, as
   [below](#looking-up-the-push-date). Look it up by digest, not by tag, since a floating tag
   moves. Each held image is on a dashboard entry of its own: none of them is in a Renovate group.
3. **Pick what to release.** A digest seven or more days old is eligible; note when a younger one
   will be. If the digest on offer can never become eligible because its tag is rebuilt more
   often than weekly, pick [one build back](#one-build-back) instead.
4. **Open a pull request of your own** setting each pin you checked to exactly that digest, in
   `versions.env` (or the `FROM` line in `build/`), and update the comment above the pin when it
   says which build it is. It takes the human path in
   [docs/MERGE_PIPELINE.md](MERGE_PIPELINE.md): CodeRabbit, then `/run-tests`, then the merge
   queue.

   Do not tick the entry's checkbox on the dashboard instead. Renovate would open the pull request
   with whatever digest is newest when it runs, which can be younger than the one checked. For
   that reason the held images are left out of the rule that lets Renovate merge on its own (the
   first of `packageRules` in `.github/renovate.json5`), and out of every group, since a group is
   one pull request labelled from all its members. If a checkbox is ticked anyway, the pull
   request arrives without the `automerge` label and waits for review, where its digest can be
   compared with the registry's date like any other.
5. **Log it** in the [release log](#release-log), in the same pull request.

### One build back

Some publishers rebuild a tag in place more often than weekly. Each rebuild is a new digest with
a new date, so the digest Renovate offers is always the youngest and never reaches seven days.
hotio does this to whisparr: every current tag is rebuilt every few days (2026-10-13, 2026-10-18,
and again by 2026-10-21), and the release tags (`v3-3.6.5-release.1886`) move along with `v3`.

Pick the newest build that has aged instead:

1. On the GHCR versions page (`https://github.com/<owner>/<repository>/pkgs/container/<name>/versions`),
   find the newest build of the same line published seven or more days ago, by a tag that names
   that one build and stays on it. For hotio that is `v3-<commit>`, after the commit of hotio's
   own repository the build came from (`v3-7fb9b23`). A row of consecutive version ids all
   published at once is a batch rebuild, not a new release.
2. Resolve that tag to its digest and read what it contains:

   ```shell
   token=$(curl -s "https://ghcr.io/token?scope=repository:hotio/whisparr:pull" | jq -r .token)
   curl -sI -H "Authorization: Bearer $token" \
     -H 'Accept: application/vnd.oci.image.index.v1+json' \
     https://ghcr.io/v2/hotio/whisparr/manifests/v3-7fb9b23 | grep -i docker-content-digest
   ```

   Then fetch the index, one platform's manifest, and its config blob, and read the config's
   `org.opencontainers.image.version` label. A label is fine for what the image contains, just
   not for its age.
3. Release that digest as step 4 above, keeping the tag the pin already uses
   (`WHISPARR_VERSION=v3@<digest>`).

### When a release changes the app

A held image can sit for months, so its first release can carry real changes, and the integration
suite is where they show. Whisparr 3.4 to 3.6 (#323) changed two things the stack depended on:
it started creating its own login on first start, and it began redirecting an anonymous request
for its UI to the login page instead of answering 401. Both failed the suite until fixed in the
same pull request. When a failure points at the app, start the pinned image fresh in the L2
engine and look at what it does, rather than guessing from the logs:

```shell
l2 --engine -- sh probe.sh   # a throwaway script under tmp/, which is gitignored
```

## Looking up the push date

Only the registry's own record counts. Two other dates look tempting and do not: the image's
`created` field and its `org.opencontainers.image.created` label are written by whoever builds
the image, so a compromised publisher can backdate them (which is why Renovate's maintainers will
not use them either), and the upstream project's release date says when the source was tagged,
not when this image was pushed.

### GHCR

The package page lists each version with its digest, its tags and how long ago it was
published: `https://github.com/users/<owner>/packages/container/package/<name>` (`orgs` in place
of `users` for an organization), or every version, untagged ones included, at
`https://github.com/<owner>/<repository>/pkgs/container/<name>/versions`. The page gives a
relative age only ("6 days ago"), so when it is close, wait for it to read seven. GitHub's
Packages API has the exact `created_at`, but needs a token with `read:packages`, which an agent
in a devcontainer-airlock workbench does not hold. GHCR itself is always reachable from a
workbench.

### quay.io

```shell
curl -s "https://quay.io/api/v1/repository/navidys/prometheus-podman-exporter/tag/?specificTag=v1.21.2" \
  | jq '.tags[0] | {name, manifest_digest, start_ts, last_modified}'
```

`start_ts` and `last_modified` are when the tag got this manifest. No login is needed. From a
workbench this needs the `quay` egress set, which `.devcontainer/egress-sets` lists.

### gcr.io

```shell
curl -s https://gcr.io/v2/cadvisor/cadvisor/tags/list \
  | jq '.manifest | to_entries[] | select(.value.tag | index("v0.55.1")) | {digest: .key, uploaded: (.value.timeUploadedMs | tonumber / 1000 | todate)}'
```

The `manifest` map is keyed by digest, with `timeUploadedMs` for each. From a workbench this
needs the `gcr` egress set (ivan-pinatti-labs/devcontainer-airlock#170), which
`.devcontainer/egress-sets` lists; a session registers its sets when it starts, so one started
before the line was on `main` cannot reach gcr.io. The command above has not been run yet:
check its output the first time.

## Release log

| Date | Image | Version and build | Digest | Pull request | Notes |
| --- | --- | --- | --- | --- | --- |
| 2026-10-21 | whisparr | `3.6.5-release.1886`, build `v3-7fb9b23` | `sha256:ddc89f9a...` | #323 | First release by hand, one build back: `v3` itself was a day old. Needed the setup and healthcheck changes above |

---

See also: [docs/DEPENDENCY_UPDATES.md](DEPENDENCY_UPDATES.md),
[docs/MERGE_PIPELINE.md](MERGE_PIPELINE.md), [docs/HARDENING.md](HARDENING.md)
