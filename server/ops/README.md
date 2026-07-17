# MeshChat server operations

The relay uses two `systemd` timers:

- `mesh-backup.timer` creates a verified, compressed SQLite backup every day and keeps the latest seven copies.
- `mesh-health.timer` checks the relay service, port, database, queue, reactions, backup age, and disk space every 15 minutes.

Useful commands on the VPS:

```bash
systemctl list-timers 'mesh-*' --no-pager
systemctl start mesh-backup.service
systemctl start mesh-health.service
systemctl status mesh-backup.service mesh-health.service --no-pager
journalctl -u mesh-backup.service -u mesh-health.service -n 50 --no-pager
cat /root/mesh_messenger/data/health.json
ls -lh /root/mesh_messenger/backups/automatic
```

Each backup has a `.sha256` checksum and JSON metadata. The backup is accepted only after SQLite reports `integrity_check=ok`.

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
