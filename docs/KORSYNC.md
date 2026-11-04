# KOReader Sync (korsync)

KOReader Sync is a self-hosted reading progress sync server for
[KOReader](https://koreader.rocks). It stores per-document reading position,
percentage, and device information in a SQLite database so multiple devices
stay in sync.

## Configuration

Set a strong `PASSWORD_SALT` in `configs/korsync/.env` before first use. This
value is appended to every password before hashing and must never change
after users are registered, since changing it invalidates all existing
passwords.

```dotenv
PASSWORD_SALT=<random-string>
```

## KOReader device setup

In KOReader: **Settings → Cloud storage → KOReader sync server**

| Field | Value |
| --- | --- |
| Server address | `https://<your-host>/korsync` |
| Username | your chosen username |
| Password | your chosen password |

Registration happens automatically on first login if the username does not exist.

With `APP_PROXY_DOMAIN` set (see
[APP_LINKS.md](APP_LINKS.md#one-host-name-per-app)), for example to
`example.com`, the server address can be the shorter
`https://korsync.example.com`, which is quicker to type on an e-reader.
`korsync.example.com` has to resolve to this host on the e-reader's network,
and the certificate has to name it, as `make generate_certificate` and
`make rotate_certificate` do. `https://<your-host>/korsync` keeps working
either way. Give the address without a path: KOReader adds `/users/auth` and
`/syncs/progress` to it and does not follow a redirect.

## User management

The server has no admin UI or management API. Use the included script, which
runs all operations inside the container via `podman exec`:

```sh
./scripts/korsync-users.sh list
./scripts/korsync-users.sh rename <old-username> <new-username>
./scripts/korsync-users.sh change-password <username>
./scripts/korsync-users.sh remove <username>
```

The same commands are available through the Makefile wrapper:

```sh
make korsync_users ARGS="list"
```

`change-password` prompts for the new password interactively so it does not appear in shell history.

`remove` deletes the user and all their synced progress records. There is no soft delete.

The container must be running for `change-password` (password hashing runs
inside the container). `list`, `rename`, and `remove` operate directly on the
database and also require the container to be running since they use
`podman exec`.

## Data

The SQLite database is stored at `configs/korsync/data/koreader-sync.db` on
the host, mounted into the container at `/app/data/koreader-sync.db`. Back
this file up to preserve user accounts and reading positions.

---

See also: [README.md](../README.md), [docs/MAKE_COMMANDS.md](MAKE_COMMANDS.md)
