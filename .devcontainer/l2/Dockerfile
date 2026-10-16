# This repository's L2 image: where its hooks run, with no network and no
# credentials (see docs/LAYERS.md in devcontainer-airlock). It adds what the
# local hooks call by name on top of the shared L2 image: shfmt.
#
# The stack and the integration suite do not run in L2; they run on the host
# against the host's podman (.devcontainer/README.md says why).
ARG L2_IMAGE=ghcr.io/ivan-pinatti-labs/airlock-l2@sha256:8841bc618dfef6013a88217d41e5d18f6cd005bbc11ab163b4034ed3897c0ac9
# hadolint ignore=DL3006
FROM ${L2_IMAGE}
USER 0:0
# hadolint ignore=DL3008
RUN apt-get update \
  && apt-get install -y --no-install-recommends shfmt \
  && rm -rf /var/lib/apt/lists/*
USER 1000:1000
