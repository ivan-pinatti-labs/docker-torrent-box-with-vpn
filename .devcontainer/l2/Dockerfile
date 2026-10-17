# This repository's L2 image: where its hooks run, with no network and no
# credentials (see docs/LAYERS.md in devcontainer-airlock). It adds what the
# local hooks call by name on top of the shared L2 image: shfmt.
#
# The stack and the integration suite do not run in L2; they run on the host
# against the host's podman (.devcontainer/README.md says why).
ARG L2_IMAGE=ghcr.io/ivan-pinatti-labs/airlock-l2@sha256:3e7cb077f9c6dfefce632ea744a1e374888986e1ab92acc9825d47a32da250e4
# hadolint ignore=DL3006
FROM ${L2_IMAGE}
USER 0:0
# hadolint ignore=DL3008
RUN apt-get update \
  && apt-get install -y --no-install-recommends shfmt \
  && rm -rf /var/lib/apt/lists/*
USER 1000:1000
