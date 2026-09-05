# Delivery Reliability: Atomic Recovery and Bounds

Follow-up: real Redis multi-process faults were exercised and presence recovery
was fixed on September 6. See `RELIABILITY_REDIS_2026-09-06.md`; the results below
record the earlier stage and do not include that follow-up.

## Changes

1. A compact account delivery intent now commits with history, the ordered sync
   journal and the processed sender mutation. Capacity errors roll back the entire
   write; no success ACK is generated for the rolled-back operation.
2. The previous experimental payload queue is retired. Negotiated v2 clients
   recover creations, edits and deletions through ordered deltas or authoritative
   snapshots. They do not receive separate stale copies of those live packets.
   A delayed request after an edit fetches the current content. ACK follows the
   device's persisted sync checkpoint, not receipt of a hint.
3. The queue stores one fixed-shape row per account, default maximum 100000,
   with 7-day expiry and cleanup batches capped at 256. Expiry leaves history and
   journal state intact, so offline devices can still recover. Admission is
   serialized across PostgreSQL workers before history row locks.

Repeated hints do not cancel an active sync. New writes can wake receivers
immediately; periodic checks recover lost Redis wake-ups with bounded backoff.
Device ownership is checked before sending. Retained intents are not unread
messages; the dashboard and metric names now distinguish them.

## Verification

- Full server suite passed: 294 tests with the feature disabled and 294 with it
  enabled, including PostgreSQL tests.
- Final focused suite passed: 38 tests, including the additional lost-Redis-wakeup
  regression added after the full runs.
- Full Flutter suite: 134 passed, including coalesced hints, failed checkpoint
  handling, account switching, outbox replay and file resume.
- PostgreSQL: real separate connections tested rollback and concurrent capacity
  admission in an isolated schema on the local E-drive lab.
- Real loopback WebSockets verified delayed recovery after editing and per-device
  ACK isolation. Broker-loss behavior uses a deterministic Redis test double.
- `git diff --check` passed.

Logs: `.review/reliable-sync-*`.

## Release State

No build, Git push or deployment was performed. Production was not modified.
The feature is still OFF unless `MESH_RELIABLE_DELIVERY_ENABLED=1` is explicitly
set. Test configuration was applied only inside local test commands/fixtures.

Before rollout: real Redis multi-process fault/load testing, slow-consumer and
large-group measurements, admission-lock contention checks, and a coordinated
worker/client canary. The local queue probe from the first stage measures the
retired design, so its latency figures do not describe this implementation.

See `server/ops/reliability_lab/README.md` for protocol details and configurable
limits. Apple Developer enrollment is not required for this local work.
