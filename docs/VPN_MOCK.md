# Local mock VPN endpoint

`qbittorrent` and `sabnzbd` both declare `depends_on: gluetun: condition:
service_healthy`, and gluetun's healthcheck only passes once a VPN tunnel
is actually established. Without real VPN provider credentials, gluetun
never reports healthy, so those two containers, and everything wired
through them (Prowlarr's own download clients, every arr app's download
client), never start. That's true today in CI without a VPN key, and for
any contributor without a paid VPN account.

`make bootstrap_tests` (see the README's "Full test coverage" section)
closes that gap with a local, credential-free WireGuard
endpoint: `docker-compose-vpn.yml`'s `vpn_mock` service, a
`linuxserver/wireguard` container running in server mode on the same host.
Gluetun connects to it for real (`VPN_SERVICE_PROVIDER=custom`), so
gluetun's own connection, health, and killswitch logic all run completely
unmodified against it. It is not a privacy feature: it's a same-host
WireGuard hop that exists purely to make gluetun's own logic exercisable
without a real provider account.

## How it gets wired

1. `scripts/enable-test-profiles.sh` applies `.env.tests`, which sets
   `VPN_MOCK_PROFILE=enabled`.
2. It then runs `scripts/seed-vpn-mock.sh`, which:
   - Skips entirely if the job already looks done: `configs/gluetun/.secret`
     holds a real key *and* `configs/gluetun/.env` already has
     `VPN_SERVICE_PROVIDER=custom`. Both have to check out, not just the
     secret: confirmed live, a run that saves the key but dies before
     pointing gluetun's config at the mock (e.g. a missing `.env` var
     further down) leaves gluetun permanently configured for its original
     real provider while holding mock key material: it dials real VPN
     servers with the wrong credentials forever and never passes its own
     healthcheck. A rerun has to recognize that half-finished state and
     finish the job, not treat the saved key as proof it's done. An
     existing *real* credential (not the mock's) is still never touched.
   - Starts just the `vpn_mock` container and waits for
     `configs/vpn_mock/config/peer1/peer1.conf`, which
     `linuxserver/wireguard` generates on first boot along with a server
     keypair. The image version is pinned by `VPN_MOCK_VERSION` in `.env`.
   - Parses that peer file's `PrivateKey`, `Address`, and the `[Peer]`
     block's `PublicKey` and `PresharedKey`.
   - Writes the private key into `configs/gluetun/.secret`, the same file
     a real credential would live in.
   - Updates `configs/gluetun/.env`: `VPN_SERVICE_PROVIDER=custom`,
     `VPN_TYPE=wireguard`, `WIREGUARD_ENDPOINT_IP` (`vpn_mock`'s static IP,
     `VPN_MOCK_IP` in `.env`; not the generic `VPN_ENDPOINT_IP`, which
     gluetun only accepts as a deprecated alias), `WIREGUARD_ENDPOINT_PORT=51820`,
     `WIREGUARD_PUBLIC_KEY`, `WIREGUARD_PRESHARED_KEY`, `WIREGUARD_ADDRESSES`,
     `VPN_PORT_FORWARDING=off` (port forwarding is a provider-specific
     API with no self-hosted equivalent), and blanks `SERVER_COUNTRIES`
     (gluetun's `custom` provider has no server list to validate a
     country against and hard-rejects a leftover real-provider value).
   - `vpn_mock`'s static IP (`VPN_MOCK_IP`) is protected from being handed
     to some other container by `SERVICES_DYNAMIC_IP_RANGE` in `.env`,
     which excludes it (and `GLUETUN_SERVICES_IP`) from the `services`
     network's dynamic allocation pool. Confirmed live, twice, before this
     range existed: a container with no static IP of its own (recyclarr)
     was dynamically handed `VPN_MOCK_IP` first, starving `vpn_mock` of
     its own address and leaving gluetun dialing an endpoint nothing was
     listening on.
3. `make bootstrap` proceeds as normal from there. Its own
   `seed-gluetun-secret.sh` step sees a populated secret and no-ops
   through its existing check, so nothing about plain `bootstrap`'s
   behavior changes for a real user pasting in a real key.

## What this unlocks

Every test that currently skips without a real VPN key becomes
exercisable, most notably `tests/test_vpn_killswitch.py`, which only
requires gluetun and the probe container to be genuinely healthy: it has
no idea whether the tunnel behind that health state is a real provider or
a local mock.

## Never for a real deployment

`VPN_MOCK_PROFILE` defaults to `disabled` in `.env.example` and stays that
way unless `.env.tests` is applied. `make bootstrap_tests` and the other test
targets apply it only inside the nested test runner (docs/TESTING.md, "Where
the suite runs"), to a throwaway copy of the tree. Running
`make enable_test_profiles` directly is another matter: it rewrites this
checkout's `configs/gluetun/.secret` and `.env` the same way plain
`make bootstrap` rewrites every other credential, so it's meant for a
disposable clone, not a deployment you care about. If you want your own real VPN, follow
README.md section 2 or `docs/VPN_PROVIDERS.md` instead.
