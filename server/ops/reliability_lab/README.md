# Isolated Reliability Lab

This lab does not use production credentials, databases, Redis keys, or user accounts.
The current cursor-based delivery implementation is experimental and OFF by default.
Do not enable it in production based only on unit tests or the queue probe.

## Available Checks

- `python -m server.ops.reliability_lab.group_probe --output E:/meshchat-reliability-lab/group-runs --participants 48 --messages 100 --slow 12 --paused 8`:
  real two-worker group recovery with slow application readers and paused TCP
  transports. Test clients explicitly reconnect after keepalive disconnects.
  Checks full message state, edits/deletions, ordered delta recovery, and four-party
  call signaling/caption translation payloads. It does not create WebRTC media,
  send audio to STT, or establish all-to-all group audio. See
  `GROUP_DELIVERY_AND_CALLS_2026-09-06.md` for results and release blockers.

- `python -m unittest server.tests.test_reliable_sync -v`: atomic history/intent
  rollback, ordered edit/delete recovery, capacity, bounded expiry, real loopback
  sockets and optional PostgreSQL concurrency. This covers the current v2 design.

- `python -m server.ops.reliability_lab.fault_probe --output E:/meshchat-reliability-lab/runs --messages 300 --delta --restart-redis`:
  two genuine relay processes, dedicated PostgreSQL database, real Redis and
  WebSocket clients. Exercises slow application reads, edits/deletes, worker
  termination, broker restart and account-presence expiry. Delta checks validate
  ordering, digest and checkpoint before ACK. Omit `--delta` for snapshots.
  Requires the local infrastructure below and `MESH_TEST_DATABASE_URL`.
  `--restart-redis` is workstation-specific: it verifies the daemon's lab pidfile
  on port 16379 and restarts only the `MeshChat-Reliability-Lab` WSL distro's Redis.
  Do not use this option with another Redis installation or shared test runs.

- `python -m server.ops.run_reliability_tests --rounds 3`: existing media, sync,
  backup and two-device fault tests plus retained-delivery and metrics tests.
- `python -m unittest server.tests.test_reliable_delivery -v`: SQLite restart,
  connection ownership, failed sends, lost PubSub notifications, lost ACKs,
  authenticated ACK deletion and account cleanup. Redis faults use a test double.
- Set `MESH_TEST_DATABASE_URL` to a **loopback** PostgreSQL database whose name
  starts with `meshchat_reliability_test` to also test two real SQL connections.
- `python -m server.ops.reliability_lab.queue_probe --messages 1000`: independent
  PostgreSQL consumers race to claim each packet. Tests ACK authorization too.
  This probes the retired v1 SQL payload queue, not current v2 delivery. These
  timings are NOT full-relay throughput or Internet delivery latency.
- `flutter test --no-pub test/mesh_socket_resilience_test.dart`: real loopback
  WebSocket tests, including duplicate delivery and failed application handling.

Run Python commands from the repository root. The application dependency set
includes `psycopg[binary]`, `redis` and `aiohttp`.

## Infrastructure

`compose.yaml` supplies isolated PostgreSQL and Redis when Docker is available.
Set `MESH_LAB_DATA_DIR` to a dedicated absolute directory on E and set a test-only
`MESH_LAB_POSTGRES_PASSWORD`. Do not point the directory at an existing database.
Both ports bind only to loopback. Stop any portable lab PostgreSQL first because
the Compose instance also uses port 15432. Docker's own image store must also be
on a drive with sufficient space; a bind-mounted database does not move images.

On the current workstation PostgreSQL 16.15 binaries and disposable database are
under `E:/meshchat-reliability-lab`. Docker Desktop was not available. A separate
Alpine WSL distro, `MeshChat-Reliability-Lab`, was imported on E; Redis 8.4.2 runs
on loopback port 16379 with persistence disabled and a 32 MB memory limit.
Real multi-process fault runs passed on this combination. The Compose stack
(including its Redis 7.4 image) has NOT been executed.
The portable PostgreSQL instance is loopback-only, contains synthetic data only,
and uses local trust authentication. Stop it when not testing. It is not a
production server configuration.

The fault probe creates and drops its own uniquely named PostgreSQL database,
uses a unique Redis key prefix and random synthetic credentials, and kills only
its own relay subprocesses. It never starts billing, push or scheduled jobs.
JSON results and subprocess logs are retained in the requested output directory.
Stop the dedicated Redis and PostgreSQL daemons after testing; do not globally
shut down other WSL distros or delete unrelated volumes.

See `RELIABILITY_REDIS_2026-09-06.md` for measured scope and remaining limits.

## Metrics

Relay workers publish bounded aggregate counters and latency histograms with
their heartbeat. No packet text, account IDs, IPs or email addresses are labels.
Prometheus counters/histograms are labeled by configured worker ID so individual
worker restarts do not corrupt rate calculation. Queue depth is shared SQL state
and is aggregated with MAX, not SUM. Histogram limits range from 10 ms to 120 s.

`dashboard.json` is an importable Grafana dashboard. Select the intended
Prometheus data source after importing. `alerts.yaml` contains Prometheus rule
definitions. Neither file installs Grafana, starts Prometheus, or configures an
Alertmanager notification destination. Keep `/health` and `/metrics` private.
An old retained packet can mean a disconnected device, not a delivery outage.

## Experimental Delivery Contract

The current client advertises `supports_reliable_sync_v2`. The server must set
`MESH_RELIABLE_DELIVERY_ENABLED=1`. Older clients keep existing live delivery.
The earlier v1 payload queue is no longer activated by this flag.

History, ordered sync journal, compact account intent and sender mutation marker
share one transaction. Queue failure rolls all of them back, leaving the sender's
durable outbox free to retry. The intent stores only account login, target cursor
and timestamp. Repeated messages coalesce into one row per account.

For negotiated clients, message creation/edit/delete and chat/group deletion are
recovered through the existing ordered delta or authoritative snapshot path;
retained copies of old message bodies are never replayed separately. Redis wakes
the target worker and a periodic SQL check recovers lost wake-ups. ACK uses the
existing authenticated account/device sync cursor, persisted after a successful
local checkpoint. A device ACK does not acknowledge another device. This is NOT
a read receipt or a claim of exactly-once network execution.

Defaults: `MESH_RELIABLE_MAX_ACCOUNTS=100000` and
`MESH_RELIABLE_RETENTION_SECONDS=604800` (7 days, minimum 60 seconds). Capacity
admission is serialized across PostgreSQL workers before history row locks.
At the hard limit, a new account intent rejects the enclosing write rather than
silently discarding delivery work. Existing account intents can still advance.
Cleanup scans/deletes at most 256 intents per pass. It never deletes history or
sync journal state. Expired intents remain recoverable from `sync_event_state`
and device `sync_cursors`; reconnect can fall back to a full snapshot.

Retry memory is bounded by connected devices, cleared on matching disconnect,
and uses 2-30 second backoff and 5-second socket deadlines. V2 keeps at most one
asynchronous hint send per connected device, coalescing duplicate wake-ups; a slow
send no longer holds the PubSub dispatcher or serializes the other retry sends.
The retired v1 retry path still uses eight sends per batch.
New live wake-ups can request recovery immediately. The client coalesces
requests; the server does not cancel an in-progress sync for duplicate hints.

Metrics `delivery_intent_accounts` and `delivery_intent_oldest_seconds` describe
retained account metadata, not undelivered messages. Tune the capacity alert if
the configured limit changes. `delivery_capacity_rejections_total` counts
admission failures.

## Required Before Enabling in Production

1. Extend the completed two-client real Redis fault runs to many slow consumers
   and actual transport backpressure. Artificial per-frame application delay
   does not prove behavior under exhausted TCP buffers or production fan-out.
2. Measure large-account/group sync costs and admission-lock contention. The
   conservative shared admission lock trades throughput for bounded storage.
3. Test a coordinated worker/client canary rollout, not a mixed old-worker fleet.
4. Deploy metrics separately, choose alert thresholds against real measurements,
   configure a notification receiver and perform a small canary rollout.

## Apple Follow-Up

After the developer account becomes available: signing/provisioning, APNs key,
TestFlight distribution and physical-device checks for terminated-app delivery,
network changes and calls. Current tests cannot establish iOS background delivery
or audio reliability. Approval timing is not assumed here.
