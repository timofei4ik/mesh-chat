# MeshChat scaling roadmap

## Completed

1. Run multiple Chat/Sync worker processes on one host.
2. Coordinate connections, presence, events, and cross-worker delivery through Redis.
3. Put WebSocket workers behind explicit nginx load balancing.
4. Move media delivery into a separate service and use content-addressed object storage.

5. Isolate calls behind dedicated signaling and TURN processes. The LiveKit SFU
   control plane is staged behind a future `call_sfu_v1` client capability.
6. Provide repeatable 1,000 to 5,000 concurrent-client load scenarios,
   including reconnect and delta-sync handshakes.
7. Export production capacity metrics, define alerts and Kubernetes HPA/PDB
   rules, and run a local process failover guard on the current VPS.

## Remaining infrastructure boundary

The checked-in autoscaling and failover configuration becomes host-redundant
only after deployment to at least two compute nodes with replicated PostgreSQL,
Redis, object storage, and TURN. A single VPS can restart processes but cannot
survive loss of its host or public network.

PostgreSQL remains the durable source of truth. Redis is coordination infrastructure and
must not become the only copy of account, chat, message, or membership data.
