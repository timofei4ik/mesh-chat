# MeshChat server operations

The relay uses two `systemd` timers:

- `mesh-backup.timer` creates a verified, compressed SQLite backup every day and keeps the latest seven copies.
- `mesh-health.timer` checks the relay service, port, database, queue, reactions, backup age, and disk space every 15 minutes.
- `mesh-reliability.timer` restores the newest backup and deeply verifies Sync v2 and media storage every day.

Useful commands on the VPS:

```bash
systemctl list-timers 'mesh-*' --no-pager
systemctl start mesh-backup.service
systemctl start mesh-health.service mesh-reliability.service
systemctl status mesh-backup.service mesh-health.service mesh-reliability.service --no-pager
journalctl -u mesh-backup.service -u mesh-health.service -u mesh-reliability.service -n 50 --no-pager
cat /root/mesh_messenger/data/health.json
cat /root/mesh_messenger/data/reliability.json
ls -lh /root/mesh_messenger/backups/automatic
```

Each backup has a `.sha256` checksum and JSON metadata. The backup is accepted only after SQLite reports `integrity_check=ok`.

For the PostgreSQL migration rehearsal and maintenance-window cutover, use
`python -m server.ops.sqlite_to_postgres` followed by
`python -m server.ops.postgres_cutover_check`. The exact procedure and rollback
boundary are documented in `server/POSTGRES_MIGRATION.md`.

Before a release, run the deeper persistence audit. It verifies Sync v2 cursor and
deduplication invariants, reaction uniqueness, every stored media file and pending
chunk, then restores the newest compressed backup into a temporary database:

```bash
cd /root/mesh_messenger
.venv/bin/python -m server.ops.reliability_audit
.venv/bin/python -m server.ops.run_reliability_tests --rounds 3
.venv/bin/python -m unittest discover -s server/tests -v
```

The audit exits with status `2` on any persistence or backup integrity failure,
so it can be used as a deployment gate.

## MeshPro billing preflight

Keep payment links and provider credentials outside Git. Copy
`meshpro.env.example` to `/etc/mesh-messenger/meshpro.env`, configure either
Boosty Telegram activation, Lava.top, the manual Sber flow, or YooKassa, set mode `600`, and reference it from the
`mesh-server` systemd service. Before exposing the checkout, run:

```bash
cd /root/mesh_messenger
set -a
. /etc/mesh-messenger/meshpro.env
set +a
.venv/bin/python -m server.ops.check_meshpro_readiness
systemctl restart mesh-server
.venv/bin/python -m server.ops.check_meshpro_readiness --live
```

The checker never prints secret values. The live pass also verifies `wg0` and
the localhost billing health endpoint.

Boosty setup and subscriber activation are documented in
`server/BOOSTY_ACTIVATION.md`.

## Android notifications after app termination

Android terminated-state notifications use Firebase Cloud Messaging. Keep the
Firebase service-account JSON outside Git and expose it to the relay through:

```bash
MESH_FIREBASE_CREDENTIALS=/etc/mesh-messenger/firebase-service-account.json
MESH_FIREBASE_PROJECT_ID=your-firebase-project-id
```

The Android APK must be built with the matching public Firebase app values:

```powershell
flutter build apk --release --dart-define-from-file=firebase_push.json
```

Copy `firebase_push.example.json` to the ignored `firebase_push.json` first.
The app registers refreshed FCM tokens with the authenticated MeshChat node;
the server removes stale tokens automatically. Message bodies stay generic so
encrypted chat content is never sent to Firebase.

## Redis and multiple relay workers

Chat/Sync workers share only live presence and transient packet fanout through
Redis. PostgreSQL remains the durable source of truth, so a Redis restart cannot
delete message history. Configure the common worker environment in
`/etc/mesh-messenger/server.env`:

```bash
MESH_REDIS_URL=redis://127.0.0.1:6379/0
MESH_REDIS_PREFIX=meshchat
MESH_WORKER_COUNT=2
MESH_REALTIME_PRESENCE_TTL_SECONDS=45
MESH_REALTIME_HEARTBEAT_SECONDS=15
```

The checked-in `ops/redis/meshchat.conf` keeps Redis local-only, disables
persistence for this intentionally ephemeral data, and caps memory at 64 MiB.
Include it from `/etc/redis/redis.conf` before enabling workers.

Install `ops/systemd/mesh-chat-worker@.service`, stop the legacy
`mesh-server.service`, then start exactly the configured number of instances:

```bash
systemctl daemon-reload
systemctl disable --now mesh-server.service
systemctl enable --now mesh-chat-worker@0 mesh-chat-worker@1
systemctl status mesh-chat-worker@0 mesh-chat-worker@1 redis-server --no-pager
```

The systemd template binds worker zero to `127.0.0.1:8870` and worker one to
`127.0.0.1:8871`. Install `ops/nginx/meshchat-realtime-upstream.conf` in
`/etc/nginx/conf.d/` and include
`ops/nginx/meshchat-realtime-location.conf` from the public TLS server block.
nginx balances new WebSocket connections with `least_conn`; Redis carries
presence and live packets between workers after the handshake.

`MESH_SERVER_PORT_BASE` is added to `MESH_WORKER_INDEX` by the server process,
so additional worker instances receive consecutive loopback ports.

Only worker zero runs billing, media HTTP, Boosty, WireGuard reconciliation,
and scheduled messages. Never set `MESH_WORKER_COUNT` above one without
`MESH_REDIS_URL`.

Verify real cross-worker signaling after deployment. The smoke command creates
and removes a temporary account, opens enough sockets to reach both workers,
and routes one call signal through Redis:

```bash
set -a
. /etc/mesh-messenger/server.env
. /etc/mesh-messenger/postgres.env
set +a
.venv/bin/python -m server.ops.smoke_realtime_workers \
  --uri wss://meshchat-losa.ru/ws
```
