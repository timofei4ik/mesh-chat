# PostgreSQL migration

The PostgreSQL runtime, full schema, data-copy tooling, and parity checks are
implemented. MeshChat still defaults to SQLite until an operator performs the
maintenance-window cutover described below.

## Safety rules

- Do not remove or rewrite the SQLite database.
- Back up SQLite before every data-copy rehearsal.
- Apply schema migrations before copying data.
- Stop all writers before the final copy and parity check.
- Require exact row-count and SHA-256 table parity before cutover.
- Keep provider webhooks on one active writer during migration.
- Never roll back to the old SQLite snapshot after PostgreSQL accepted new
  writes. Restore or reverse-migrate those writes first.

## Prepare a database

Install the server dependencies and provide a dedicated PostgreSQL URL:

```powershell
python -m pip install -r server/requirements.txt
$env:MESH_DATABASE_URL = "postgresql://meshchat:password@localhost/meshchat"
python -m server.ops.migrate_postgres
```

On Linux:

```bash
python -m pip install -r server/requirements.txt
export MESH_DATABASE_URL='postgresql://meshchat:password@localhost/meshchat'
python -m server.ops.migrate_postgres
```

The migration runner records each applied file in `schema_migrations`.
Re-running it is safe and does not execute an already recorded migration.

## Rehearse the copy

Keep the production server on SQLite and copy a recent backup into a disposable
PostgreSQL database:

```bash
export MESH_DATABASE_URL='postgresql://meshchat:password@localhost/meshchat'
python -m server.ops.sqlite_to_postgres copy \
  --sqlite-path /root/mesh_messenger/data/server.db
python -m server.ops.postgres_cutover_check \
  --sqlite-path /root/mesh_messenger/data/server.db
```

The copy command is resumable and idempotent. It upserts primary-keyed rows,
records progress in `sqlite_migration_progress`, and resets PostgreSQL identity
sequences. The check requires exact normalized fingerprints for every table.

## Maintenance-window cutover

1. Stop the relay, billing endpoint, Boosty bot, scheduler, and every process
   that can write to SQLite.
2. Create and verify the usual SQLite backup.
3. Run the final `copy` command.
4. Run `postgres_cutover_check`; do not continue unless it prints
   `CUTOVER READY`.
5. Configure the service:

```bash
MESH_DATABASE_BACKEND=postgres
MESH_DATABASE_URL=postgresql://meshchat:password@localhost/meshchat
```

6. Start one relay instance and run login, direct-message, group, channel,
   file-transfer, reaction, sticker, and Sync v2 smoke tests.
7. Re-enable external writers only after the smoke tests pass.
8. Keep the immutable SQLite backup for the retention period.

SQLite remains the default when `MESH_DATABASE_BACKEND` is absent.

## Rollback boundary

Before PostgreSQL receives new writes, stop the service and restore
`MESH_DATABASE_BACKEND=sqlite`; the original SQLite file is untouched.

After PostgreSQL receives writes, the old SQLite snapshot is stale. A direct
configuration rollback would lose messages and account changes. Enter
maintenance mode and restore PostgreSQL or build a reviewed reverse migration
before switching back.

## Verification coverage

- all checked-in migrations are idempotent;
- PostgreSQL schema covers every server table;
- populated SQLite copy and repeat-copy parity;
- direct history and permanent deletion across devices;
- groups, owners, membership, channels, files, reactions, and leave;
- resumable file transfer;
- account-scoped sticker libraries;
- Sync v2 delta and operation deduplication.
