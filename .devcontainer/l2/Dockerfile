# This repository's L2 image: where its hooks run, with no network and no
# credentials (see docs/LAYERS.md in devcontainer-airlock). It adds nothing to
# the shared L2 image today: shfmt, the one tool it used to add, now comes
# from its own pre-commit hook. The file stays so the shared image's digest
# is pinned here, and so a tool a hook needs later has somewhere to go.
#
# The stack and the integration suite do not run in L2; they run on the host
# against the host's podman (.devcontainer/README.md says why).
ARG L2_IMAGE=ghcr.io/ivan-pinatti-labs/airlock-l2@sha256:de98a1771bf8fb1471154d28b180bc5f4f488a4e11bfadea3705102e5ed15918
# hadolint ignore=DL3006
FROM ${L2_IMAGE}
USER 1000:1000
