# MeshChat Reliability Review - 2026-09-05

Baseline: `dcfe0b846c973c7837d91546987bf8de1a0b3517` (1.0.94+197).
Scope: current Flutter client and Python relay, with code inspection and local
failure-injection/unit/integration tests. This is not a certification that every
feature works on every device. No production data, configuration or deployment
was changed. No release binaries were built.

## Findings Fixed

### P1 - Committed messages could miss immediate recipient delivery

`server/server_mutations.py`, `execute_history_mutation`.
The sender ACK was awaited after persistence but before routing. A sender socket
failure aborted routing, even though reconciliation would subsequently report
the message as accepted. Transport errors sending this ACK no longer prevent
recipient routing. Persistence errors are not swallowed. Added a test that
disconnects the sender after commit and checks that routing still runs.

### P1 - Old outbox work could use a new account's connection

`mobile/meshchat_mobile/lib/src/services/mesh_socket.dart`.
Pending storage writes, reads and reconnect callbacks could resume after a
session change and use the current socket. Operations now capture the originating
session and connection generation. Old work remains associated with its original
durable store; it cannot send through a replacement connection. Close detaches
state before awaiting socket cleanup. Added delayed-write and delayed-file-read
account-switch tests. Existing reconnect, lost-ACK and reconciliation tests remain.

### P1 - Web push blocked the relay event loop

`server/server_push.py`, `send_web_push_for_packet`.
The synchronous HTTP client in `webpush()` ran in the async packet handler.
External push latency therefore stalled other work on the same relay worker.
Moved this network call to `asyncio.to_thread`, retaining timeout and expired
subscription cleanup. A test verifies that the call runs outside the event-loop
thread. This removes a blocking path; no production latency percentage is claimed.

### P1 - A scheduled send could duplicate history after a retry

`server/server_scheduler.py`, `dispatch_due_scheduled_messages`.
Each attempt generated a new random message ID. Failure after persistence but
before completing the scheduled run could create a second history row next time.
IDs now derive deterministically from schedule ID and due time. Retry timestamps
are stable as well; separate recurring runs still have separate IDs. Regression
test verifies a routing failure followed by retry produces only one history row.

### P1 - Early ICE candidates could be applied before remote SDP

`mobile/meshchat_mobile/lib/src/services/call_service_io.dart` and
`call_service_web.dart`.
Having a peer connection did not mean it was ready to accept remote candidates.
Candidates now wait for successful remote-description installation on that peer.
The readiness reference resets during teardown. Added a fake-peer test covering
candidates before, during and after SDP installation. Real network transitions,
TURN/SFU operation and native audio still require device testing.

### P2 - File upload could exceed its unacknowledged-chunk window

`mobile/meshchat_mobile/lib/src/services/mesh_socket.dart`, `_flushFileOutbox`.
Calling flush while four chunks were in flight selected an additional chunk.
Repeated flushes could bypass backpressure. A full window now stops selection.
The regression test reproduces six chunks being sent where four were permitted.

### P2 - Disk failure silently bypassed durable delivery

`mobile/meshchat_mobile/lib/src/services/mesh_socket.dart`, `_queueMutation`.
After a failed local write, the fallback still sent the packet without a durable
row. A lost ACK then had no recovery path. The client now reports a failed message
through its existing delivery-state handler without sending an untracked packet.
Failures after successful persistence leave the durable retry path intact.
Added a no-space-left test.

### P2 - Malformed input and repeated handshakes corrupted connection handling

`server/server_connection.py`, `handle_connection`.
Valid JSON that was not an object and invalid UTF-8 raised outside the parser's
error handling. Repeated handshakes could rebind one socket and leave stale
registrations. Non-packet frames are ignored; authenticated connections cannot
handshake again. The source is bound to the authenticated node after rejecting
explicit forgeries. Added malformed-frame and repeated-handshake tests.

### P2 - Photo alignment repeated expensive work and failed on tiny images

`mobile/meshchat_mobile/lib/src/pages/document_scanner_page.dart`.
Full-image decoding occurred on every corner-drag rebuild. Geometry and initial
corners are now computed once, off the UI isolate on native platforms. Output
dimensions no longer use an invalid clamp for small images and are capped at
4096 per axis. Added processing/disposal guards and error recovery. Extended the
widget test to open alignment, process a 1x1 image and return to the editor.

## Remaining Risks And Next Validation

1. **P2: synchronous PostgreSQL work can still block a relay worker.**
   `server/persistence/postgres.py:273` executes synchronous psycopg operations;
   persistence is called directly by async handlers. Measure event-loop lag,
   transaction duration and p95/p99 ACK latency under realistic load before moving
   transactions to async connections or isolated worker-owned connections. Do not
   put shared transactions into arbitrary threads as a quick fix.
2. **P2: cross-worker live delivery is not an end-device receipt.**
   `server/server_realtime.py:250` returns success for a Redis publish with a
   subscriber, before the destination socket confirms receipt. History/delta sync
   remains the recovery mechanism. Test worker failure between publish and local
   delivery on a disposable PostgreSQL/Redis environment; consider a durable
   relay delivery queue with explicit receipts if immediate recovery is required.
3. **Cryptographic design is not independently audited.**
   `mobile/meshchat_mobile/lib/src/services/mesh_crypto.dart:30` derives the initial
   identity from login/password. The current envelopes are not a ratcheting
   protocol. Offline password-guessing resistance and forward secrecy require a
   separate design/migration review, not a silent key change that risks history.
4. **Device and production coverage remains incomplete.** Local tests do not
   prove background push delivery, native media permissions, real TURN/SFU calls,
   Wi-Fi/cellular handover, weak-device memory use or provider uptime. Payment,
   email and AI integrations use fakes in local tests, not real charges/requests.
5. **Not every feature has end-to-end tests.** Passing the suite means the tested
   contracts passed; it is not proof that every screen, race or failure is covered.

## Verification

Results: 277 server tests ran, 276 passed and one real-PostgreSQL migration test
was skipped because no test DSN was configured. All 130 Flutter tests passed.
After the final constructor/lint adjustments, the 19 directly affected Flutter
tests passed again. `flutter analyze --no-pub` reported no issues.

Local-only logs are in `.review/` (not committed or release artifacts):

- `server-audit-final.log`: full server unittest discovery.
- `flutter-audit-final.log`: full Flutter test suite.
- `flutter-audit-analyze-final.log`: Flutter analyzer.
- `socket-baseline.log`, `file-window-baseline.log`, and targeted runs document
  development checks; the final logs supersede earlier failures.

Server tests use isolated local fixtures. The real PostgreSQL migration test
requires `MESH_TEST_POSTGRES_URL` and must not be pointed at production.
No additional large staging workspace or release cache was created.
