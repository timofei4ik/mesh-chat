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
