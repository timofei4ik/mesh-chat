# Calls, capacity, and failover

## Current production topology

- nginx balances `/ws` across at least two Chat/Sync workers.
- Chat workers validate call packets and enqueue them into a Redis Stream.
- Two `mesh-call-signaling@` consumers route transient WebRTC signaling.
- coturn relays media when a direct peer-to-peer route is unavailable.
- `mesh-metrics` exposes capacity gauges for Prometheus.
- If every signaling consumer disappears, the producer heartbeat gate restores
  the old direct route automatically. Calls remain available, with reduced
  isolation, until the signaling service recovers.

The current client media plane remains WebRTC P2P/TURN. LiveKit is staged only
as an SFU configuration because switching group media to an SFU requires a
client capability and a rolling client release.

## Single-VPS rollout

```bash
install -m 600 server/ops/call-signaling.env.example \
  /etc/mesh-messenger/call-signaling.env
install -m 644 server/ops/systemd/mesh-call-signaling@.service \
  /etc/systemd/system/
install -m 644 server/ops/systemd/mesh-metrics.service \
  /etc/systemd/system/
install -m 644 server/ops/systemd/mesh-failover.service \
  server/ops/systemd/mesh-failover.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now mesh-call-signaling@0 mesh-call-signaling@1
systemctl enable --now mesh-metrics mesh-failover.timer
systemctl restart mesh-chat-worker@0 mesh-chat-worker@1
curl --fail http://127.0.0.1:8781/health
curl --fail http://127.0.0.1:8782/health
curl --fail http://127.0.0.1:8780/metrics
```

Set `MESH_CALL_SIGNALING_ENABLED=1` in
`/etc/mesh-messenger/call-signaling.env`. Chat workers and signaling consumers
must use the same `MESH_REDIS_URL` and `MESH_REDIS_PREFIX`.

## Load gates

Run from a separate Linux host so the generator does not compete with the VPS:

```bash
python -m server.ops.load_test_account --count 1000 \
  --login load-test --password 'use-a-long-random-password' \
  --output /tmp/meshchat-load-accounts.json
python -m server.ops.load_test_ws --clients 1000 \
  --ramp-per-second 10 --hold-seconds 300 \
  --accounts-file /tmp/meshchat-load-accounts.json
python -m server.ops.load_test_account --count 2500 \
  --login load-test-2500 --password 'use-another-long-random-password' \
  --output /tmp/meshchat-load-accounts-2500.json
python -m server.ops.load_test_ws --clients 2500 \
  --ramp-per-second 25 --hold-seconds 300 \
  --accounts-file /tmp/meshchat-load-accounts-2500.json
python -m server.ops.load_test_account --count 5000 \
  --login load-test-5000 --password 'use-a-third-long-random-password' \
  --output /tmp/meshchat-load-accounts-5000.json
python -m server.ops.load_test_ws --clients 5000 \
  --ramp-per-second 50 --hold-seconds 600 \
  --accounts-file /tmp/meshchat-load-accounts-5000.json
python -m server.ops.load_test_account --delete --count 1000 \
  --login load-test --password 'use-a-long-random-password'
python -m server.ops.load_test_account --delete --count 2500 \
  --login load-test-2500 --password 'use-another-long-random-password'
python -m server.ops.load_test_account --delete --count 5000 \
  --login load-test-5000 --password 'use-a-third-long-random-password'
```

Provision a distinct account per virtual client. Reusing one account across
thousands of devices intentionally benchmarks account fanout and snapshot
contention instead of ordinary user capacity.

Do not proceed to the next level unless failed connections are zero, p95
handshake latency stays below 1.5 seconds, call pending events remain below
100, and memory has at least 25% headroom.

Authentication deliberately uses an expensive password hash. On a two-core
host, begin at 10 new connections per second so this test measures steady
connected-client capacity instead of only password-check throughput. Run a
separate short burst profile when sizing authentication workers. The server
prewarms bounded Redis pools and computes password hashes outside the
WebSocket event loop, so a login burst cannot starve established sessions.

## Failover boundaries

The systemd guard repairs failed application processes on one host. Kubernetes
HPA/PDB manifests provide pod autoscaling and rolling availability across
nodes. Neither protects against total loss of a single VPS. Real host-level
failover additionally requires:

1. a second host or availability zone;
2. PostgreSQL replication with an automated leader (for example Patroni);
3. Redis Sentinel or managed Redis;
4. replicated object storage;
5. DNS or load-balancer health checks in front of both ingress nodes;
6. TURN nodes in at least two public networks.

PostgreSQL and stored media must never fail over to stale copies. Test restore
and promotion before directing public traffic to a standby.
