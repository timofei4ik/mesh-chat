# MeshChat scaling roadmap

## Completed

1. Run multiple Chat/Sync worker processes on one host.
2. Coordinate connections, presence, events, and cross-worker delivery through Redis.
3. Put WebSocket workers behind explicit nginx load balancing.
4. Move media delivery into a separate service and use content-addressed object storage.

## Next

5. Isolate calls behind dedicated signaling, TURN, and SFU infrastructure.
6. Load-test 1,000 to 5,000 concurrent clients, including reconnect and delta-sync scenarios.
7. Add production metrics, capacity alerts, autoscaling rules, and failover procedures.

PostgreSQL remains the durable source of truth. Redis is coordination infrastructure and
must not become the only copy of account, chat, message, or membership data.
