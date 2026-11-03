# Why Podman over Docker?

Both support rootless containers, but the key difference is architectural. Docker always requires
a background daemon (`dockerd`) running on the host. Even in rootless mode, that daemon is a
persistent process managing all your containers. Podman is **daemonless**: each container is a
direct child process of the user who launched it, with no central coordinator. When you run
`podman compose up`, your containers are just processes owned by your user account, nothing more.

For a stack that handles private network traffic, eliminating that daemon removes a whole class of
risk: there is no long-running privileged process to exploit, no Unix socket to misconfigure, and
no single point of failure that can take down every container at once.

**Already using Docker and don't want to change your workflow?** Install the `podman-docker`
compatibility package. It drops in a `docker` wrapper that forwards all `docker` and `docker
compose` commands to Podman transparently. Your existing scripts, aliases, and muscle memory
continue to work unchanged.

```shell
# Fedora/RHEL
sudo dnf install podman podman-docker podman-compose xmlstarlet wireguard-tools

# Debian/Ubuntu
sudo apt install podman podman-docker podman-compose xmlstarlet wireguard
```

yq comes from [mikefarah/yq's install instructions](https://github.com/mikefarah/yq#install)
(v4), on every distribution. Do not `apt install yq` on Debian or Ubuntu: that package is
[kislyuk/yq](https://github.com/kislyuk/yq), a different tool that prints JSON by default, so
the scripts' in-place edits could rewrite a YAML config as JSON. `make check_requirements`
refuses anything but mikefarah/yq v4.

Set `CONTAINER_RUNTIME=podman` (or `docker`) in your `.env` file to make your choice explicit. If
left unset, the `Makefile` auto-detects: Podman wins when both are installed.

## The Podman exporters need podman 5.8.0 or later

`podman_exporter` and `podman_limits_exporter` (both off by default) set `userns_mode`, and
podman-compose runs every service in a pod. Podman before 5.8.0 refuses that combination when it
creates the container:

```text
Error: --userns and --pod cannot be set together
```

That includes podman 5.7.0, the version Ubuntu 26.04 ships. Podman 5.8.0 dropped this check
([containers/podman#26848](https://github.com/containers/podman/issues/26848)) in favor of one that
refuses only a pod with an infra container, and podman-compose's pod has none. With either exporter
enabled on an older podman, `make start` and `make start_observability` stop before starting
anything and list the three ways out:

- Upgrade podman to 5.8.0 or later.
- Run the stack without a pod: `make start "COMPOSE=podman-compose --in-pod false"`. Pass the same
  `COMPOSE=` to `stop`, `restart` and every other target that runs compose (`make down` on podman
  runs `scripts/podman-down.sh`, which does not use it). Each service already has
  its own networks, so the pod shares nothing they depend on, but anything that finds this stack's
  containers by pod name has no pod to find: the Podman dashboard's pod selector and
  `tests/test_observability.py`.
- Disable both exporters: `PODMAN_EXPORTER_PROFILE=disabled` and
  `PODMAN_LIMITS_EXPORTER_PROFILE=disabled` in `.env`. `make enable_test_profiles` does this by
  itself on podman before 5.8.0.

To check that a container's `userns_mode` took effect, look at `.HostConfig.IDMappings` or run
`id` inside the container. `podman inspect --format '{{.HostConfig.UsernsMode}}'` reports `private`
even when `keep-id` is applied, so it cannot tell.

## Using ports 80 and 443 with rootless Podman or rootless Docker

Both runtimes in rootless mode run as your regular user, and the Linux kernel blocks unprivileged
users from binding ports below 1024 by default. The default configuration therefore uses `8080`
and `8443` so everything works out of the box without any extra steps. `make bootstrap` asks about
this interactively (defaulting to the rootless-safe `8080`/`8443`), running the `sysctl` command
below with `sudo` on your behalf if you opt in to the standard ports; the rest of this note is for
setting it up by hand instead, or afterward if you skipped the prompt.

If you prefer the standard ports, set `NGINX_HTTP_PORT=80` and `NGINX_HTTPS_PORT=443` in your
`.env`, then lower the kernel's port boundary. To apply it for the current session only (resets on
reboot):

```shell
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
```

To make it permanent across reboots, add the following line to `/etc/sysctl.conf`:

```text
net.ipv4.ip_unprivileged_port_start=80
```
