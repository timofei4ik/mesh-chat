# Real Redis Fault Verification

## Scope and Isolation

Two independent Python relay processes, PostgreSQL 16.15 on loopback port 15432,
Redis 8.4.2 on loopback port 16379, and two real WebSocket clients. All accounts,
messages and credentials are synthetic. Databases and key namespaces are unique
per run and cleaned afterwards. Runtime files and run logs are on E, under
`E:/meshchat-reliability-lab`. No production configuration, data, builds, Git
remotes or deployed services were changed.

Redis runs inside a separate Alpine WSL distro imported on E from the
[official minirootfs](https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/)
whose SHA256 was checked. Docker Desktop was unavailable; the Compose
Redis 7.4 image was not tested. This is not a production capacity benchmark.

## Defects Reproduced and Fixed

1. Redis restart erased device presence. Heartbeats only extended existing keys,
   so they could not restore live sockets. Recovery hints then failed the session
   ownership check. Run `006504436e` reproduced an undelivered message after the
   broker returned, exceeding the 55-second observation window.
2. Account-to-device sets were given a TTL on registration but not refreshed.
   Long-lived sockets could disappear from account fan-out even while their
   individual presence keys stayed alive.

The coordinator now retains registration metadata for local sessions and
atomically restores missing presence plus account membership in Redis. It never
overwrites a different session owner. A mismatched old local connection is closed
and loses its restoration metadata. Registration, heartbeat restoration and
disconnect are serialized to prevent a delayed heartbeat from reviving a signed
out session. Account IDs are normalized consistently at registration.

After complete broker data loss, competing live sockets cannot infer historical
registration order from Redis. The first successful restoration claims the key;
other sessions are fenced and reconnect. This does not promise newest-session
preference across total registry loss.

## Real Fault Runs

| Run | Mode | Load | Worker kill/reconnect | Empty Redis restart without client reconnect |
| --- | --- | --- | --- | --- |
| `0e1b18c9d0` | Snapshot | 100 messages | Passed | Passed |
| `a26c534e7e` | Delta canary | 300 messages | Passed | Passed |

The delta canary enabled `MESH_SYNC_V2_DELTA_TEST_ACCOUNTS` for the two synthetic
accounts only. It applied nine delta checkpoints and verified all 305 sender
mutation acknowledgements. Delivery of edits/deletions remained correct after
restart. Checks verify event order, count, SHA256 digest and checkpoint before
ACK. Explicit account-set expiry also recovered automatically.

The slow receiver waits 75 ms before processing each incoming frame, with a
one-frame WebSocket receive queue. The 300-message run completed that phase in
25.26 seconds. A single baseline message applied in 84.2 ms on local loopback;
neither measurement estimates Internet latency or supported user count.

Earlier run `f00ba0808a` passed the delivery/fault stages but correctly failed the
probe's coverage assertion because delta had not been enabled on the server.
It is not counted as a delta pass. JSON results and worker logs remain in
`E:/meshchat-reliability-lab/runs/<run-id>/`.

## Regression Checks

- Full server discovery with experimental delivery enabled: 300 tests, 299
  passed and one skipped because its separate PostgreSQL URL was unset.
- PostgreSQL persistence module rerun with that URL: all 11 passed, including
  the previously skipped real migration-idempotence check.
- Focused realtime/delivery/sync modules with delivery disabled by default:
  all 24 passed (some dedicated tests explicitly enable their own fixtures).
- Five new presence regressions cover broker data loss, account TTL renewal,
  stale ownership, disconnected sessions and heartbeat/disconnect ordering.
- `git diff --check` passed. Flutter code was not changed in this follow-up;
  no client rebuild was performed.

Logs: `.review/redis-fault-server-enabled.log`,
`.review/redis-fault-server-disabled.log`,
`.review/redis-fault-postgres-migrations.log`.

The complete E-drive lab, including the pre-existing PostgreSQL runtime, occupies
approximately 0.60 GiB. Temporary per-run databases and Redis keys were removed.

## Remaining Release Gates

- Many recipients and large groups, actual TCP backpressure, long outage/soak
  tests and admission-lock contention are not established by two-client runs.
- The lab validates the server protocol, not Flutter UI checkpoint persistence
  or physical-device background delivery. Existing client tests are separate.
- Production remains unchanged and the new delivery feature remains OFF by
  default. Before deployment, use a separate staging relay with compatible
  clients and all workers on the same protocol revision. Configure monitoring
  and rollback before enabling production traffic; the delivery flag is global,
  unlike the account-scoped delta test flag.
- APNs, terminated-app delivery and TestFlight checks still require the Apple
  account/device setup. No claim of full iOS delivery verification is made.
