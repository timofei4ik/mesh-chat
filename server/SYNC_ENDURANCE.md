# Sync endurance test

The endurance runner starts an isolated MeshChat server on localhost with a
temporary database. It never connects to or modifies the production database.

Each iteration alternates between two devices of the same account and checks:

- live delivery to another account and the second account device;
- reconnect and delta recovery while one device is offline;
- a lost mutation ACK followed by account-scoped server reconciliation;
- duplicate operation delivery without a duplicate message;
- permanent deletion and tombstone recovery;
- a full server restart in the middle of the run;
- identical final snapshots on phone, desktop, and a clean installation;
- absence of duplicate messages, mutation markers, and reactions.

## Short local or CI run

```powershell
python -m server.ops.run_sync_endurance --rounds 3 --iterations 48
```

## Twelve-hour soak

```powershell
python -m server.ops.run_sync_endurance `
  --duration-hours 12 `
  --iterations 120 `
  --report data/sync-endurance-12h.json
```

The report is rewritten atomically after every completed round. If the process
or machine stops, the last completed round remains available in the JSON file.
Use 12 hours first; run 24 hours before a larger production rollout.

Every round runs in a fresh Python child process. This keeps the soak focused
on Chat/Sync correctness instead of accumulating event-loop and WebSocket test
harness state across thousands of temporary servers. The parent report records
per-round duration, process resource counters, and the child output tail on a
failure. Live delivery still has a strict two-second deadline; timeout details
include the exact iteration and stage plus database and connection state.

The normal release reliability gate also runs one short round:

```powershell
python -m server.ops.run_reliability_tests
```
