# Reliability Work: 2026-09-05

Historical first-stage report. The payload-queue limitations below are superseded
by the cursor-based design in `RELIABILITY_DELIVERY_2026-09-05.md`.

## Completed Locally

- Isolated portable PostgreSQL 16.15 on E, no production database access.
- Experimental SQL-backed live delivery for direct/group messages, capability
  negotiation, authenticated processing ACKs, retries and ownership fencing.
- Client retry suppression after successful handling; no ACK after handler failure.
- Close the superseded connection when a device moves between relay workers.
- Aggregate commit/sync/delivery timings, failure counters and event-loop delay.
- Fix false Redis-down readings before the first call stream exists.
- Prepared Grafana dashboard, Prometheus alert rules and Docker Compose lab.
- Added replay, concurrent claim, account cleanup and monitoring regression tests.

## Verification

- Server suite: 286 tests passed, including real PostgreSQL migration checks.
- Flutter suite: 132 tests passed.
- Flutter analyze: no issues.
- PostgreSQL queue probe: 1000 synthetic messages, two concurrent consumers,
  no duplicate claims or lost ACKs; p50 6.85 ms, p95 8.10 ms, maximum 19.13 ms.
  This measures local SQL operations only, not full messenger performance.
- `git diff --check`: passed.

Logs are in `.review/reliability-stage-*`. Portable lab files occupy about 0.49 GiB
on E. No release builds were created and no production service was changed.

## Not Yet Complete

This is the first local stage, not completion of all five reliability workstreams.
Docker Desktop was unavailable. Real Redis broker/multi-process fault testing,
production metrics deployment and notification routing remain pending. Redis
notification-loss tests currently use a deterministic broker double.

The new queue is OFF by default (`MESH_RELIABLE_DELIVERY_ENABLED` must explicitly
equal `1`). Do not enable it in production yet: atomic staging with history,
replay after newer deletions/edits, retention and storage limits need further work.
See `server/ops/reliability_lab/README.md` for the rollout checklist and commands.

Physical-device testing of APNs delivery, terminated apps, network handover and
call audio remains necessary. After the Apple Developer account becomes available,
the next Apple-specific steps are signing, APNs credentials and TestFlight.
