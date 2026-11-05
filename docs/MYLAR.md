# Mylar

Mylar is the comics tracker/manager in this stack.

## Custom image

The upstream image uses `DOCKER_MODS: linuxserver/mods:universal-package-install`
with `INSTALL_PIP_PACKAGES: pyOpenSSL`, which installs `pyOpenSSL` into the
linuxserver virtualenv (`/lsiopy`) at every container start.

This stack builds a custom image that pre-installs `pyOpenSSL` at build time,
eliminating the mod overhead on every restart.

### Rebuild

Rebuild the image after pulling a new base image version or after changing
`MYLAR_VERSION` in `.env`:

```shell
make build_images
```

Then recreate the container:

```shell
podman stop mylar && podman rm mylar && make start
```

### Dockerfile

`build/mylar/Dockerfile` installs `pyOpenSSL` directly into `/lsiopy` using the
linuxserver wheel index:

```dockerfile
RUN /lsiopy/bin/python3 -m pip install --no-cache-dir \
    -f https://wheel-index.linuxserver.io/ubuntu/ \
    pyOpenSSL
```

---

## Session cookie scoping

Mylar and LazyLibrarian are both cherrypy apps that default to a session
cookie literally named `session_id`, scoped to `Path=/` unless told
otherwise. Left alone, the browser holds only one `session_id` cookie for
the whole domain, so visiting one app overwrites the other's session; the
app whose cookie got overwritten then bounces every subsequent request back
to its own login page, indistinguishable from a real login bug. `nginx`'s
`/mylar/` and `/lazylibrarian/` locations in
`configs/nginx/templates/default.conf.template` each carry a
`proxy_cookie_path` rewrite that scopes the cookie to its own prefix,
which stops the collision. Confirmed live: logging into Mylar, then
LazyLibrarian, in the same cookie jar previously evicted Mylar's session on
the very next request; with the rewrite in place both stay logged in.

## qBittorrent with self-signed certificates

Mylar talks to qBittorrent over HTTPS with this stack's self-signed
certificate through the "Ignore SSL warnings" toggle in its qBittorrent
settings (`qbittorrent_ignore_ssl` in `config.ini`), which the seeded
`config.ini.example` turns on.

The toggle is Mylar's own since v0.11.0
([MylarComics/mylar3#23](https://github.com/MylarComics/mylar3/pull/23)).
Before that, this stack bind mounted five patched source files over the image
to add it, and held `MYLAR_VERSION` at `v0.9.0-ls252` so an upstream bump could
not land under them; both went with issue #106. The wrapper image above is
still needed: the base image does not ship `pyOpenSSL`, which Mylar uses for
that HTTPS connection.
