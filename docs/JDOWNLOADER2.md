# jDownloader2

jDownloader2 is exposed on `JDOWNLOADER2_HTTP_PORT=5800` (VNC web interface) and
`JDOWNLOADER2_API_PORT=3128` (local REST API).

## Mylar connectivity

Mylar reaches jDownloader2 at `jd2_url = http://<gluetun IP>:3128` (set in
`configs/mylar/config/mylar/config.ini.example`) and its connection test hits
`/jd/version`, part of jDownloader2's older `/jd` namespace. That namespace
only answers once `deprecatedapienabled` is on, and by default jDownloader2
also restricts both that namespace and its main REST API
(`externinterfaceenabled`, the one `linkgrabberv2/addLinks` and friends live
under) to loopback only, which Mylar's container can never reach since it
does not share jDownloader2's network namespace.

`make configure_jdownloader2_api` (part of `bootstrap`, run right after
`make start`) opens both up by editing
`configs/jdownloader2/config/cfg/org.jdownloader.api.RemoteAPIConfig.json`
directly: `externinterfacelocalhostonly` and `deprecatedapilocalhostonly`
both set to `false`, `deprecatedapienabled` set to `true`. This can't be
done the way Jellyfin's `network.xml` is, by seeding a `.example` file
before jDownloader2's first boot: the base image's own
`55-jdownloader2.sh` init script only populates `/config/cfg` with its
full set of default files if that directory does not already exist yet
(`[ -d /config/cfg ] || cp -rv /defaults/cfg /config/cfg`). Seeding even
one file into it ahead of time makes the directory "already exist," so
every other default file, including
`org.jdownloader.settings.GraphicalUserInterfaceSettings.json`, read on
every boot, never gets created, and jDownloader2 crash-loops forever
(confirmed live: a pre-seeded `RemoteAPIConfig.json.example` alone broke
a fresh bootstrap outright). `configure_jdownloader2_api` waits for
jDownloader2 to generate its own config on first boot, then stops the
container, edits the file that already exists, and starts it again, the
same stop-edit-start pattern used everywhere else in this repo for a
running app's config.

## Web GUI authentication

The `jlesage/jdownloader-2` image serves the web interface behind
its own nginx `auth_request` gate. `configs/jdownloader2/.env` sets `SECURE_CONNECTION=1`
(https with a self-signed certificate) and `WEB_AUTHENTICATION=1` to require a login; the
credentials come from `WEB_AUTHENTICATION_USERNAME`/`WEB_AUTHENTICATION_PASSWORD` in
`configs/jdownloader2/.env.secrets` (gitignored, copy from `.env.secrets.example`), following the
same committed-template-plus-gitignored-secrets pattern as `configs/grafana/`; see
[COMPOSE_CONVENTIONS.md](COMPOSE_CONVENTIONS.md). Both env files are only read at container
creation, so a password change needs a recreate, not a restart (with the image pins exported, see
[MAKE_COMMANDS.md](MAKE_COMMANDS.md#image-versions)):
`podman-compose --file docker-compose.yml --profile enabled up -d --force-recreate --no-deps jdownloader2`.
The healthcheck and the nginx reverse-proxy upstream both target `https://` for this reason.
`make rotate_passwords SERVICE=jdownloader2` handles the password rotation and recreate; see
[ROTATION.md](ROTATION.md).

## Memory tuning

The `jlesage/jdownloader-2` image runs the JVM alongside an X11 server and
VNC web layer. Without explicit heap limits, the JVM applies an ergonomic default of roughly 25%
of the container memory ceiling, which on a 1 GB limit is ~250 MB; combined with the GUI layer the
container can reach ~1 GB at idle after opening the web GUI. The image reads the heap cap from
`configs/jdownloader2/.env` and additional JVM options from
`configs/jdownloader2/config/JDownloader2.vmoptions`:

```dotenv
JDOWNLOADER_MAX_MEM=384m
```

```text
-Xms64m
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:+UseStringDeduplication
-XX:MaxMetaspaceSize=128m
```

This caps the heap at 384 MB and keeps idle memory within the 1 GB container limit.

## Bandwidth scheduling

jDownloader2 uses the EventScripter extension to apply the same
100 Mbps day / 500 Mbps night schedule as the other downloaders. The script is configured in
`configs/jdownloader2/config/cfg/org.jdownloader.extensions.eventscripter.EventScripterExtension.scripts.json`
with an INTERVAL trigger. It tracks the last applied limit via `getProperty`/`setProperty` and
calls `setSpeedlimit()` once per hour. The EventScripter sandbox's `setSpeedlimit(int bps)` function
is a direct
`ScriptEnvironment` method available in all event contexts; `callAPI()` and Java package access
are not available in the INTERVAL context.
