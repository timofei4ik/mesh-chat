# Group Delivery and Calls: Verified Scope

This is the earlier audit. The subsequent bounded-mesh and shared-caption
implementation is documented in `GROUP_AUDIO_AND_SHARED_CAPTIONS_2026-09-06.md`.

## Release Blocker: Group Audio

The Flutter group-call path is a star of separate WebRTC peer connections:
`startGroupCall` creates one CallService per invitee; `acceptCall` connects an
invitee's primary CallService to the initiator. There are no guest-to-guest
connections in that path. CallService publishes local microphone tracks, not a
mix of the other guests' tracks. SFU access exists on the server, but this
controller does not join a shared media room. Therefore successful invitation
and answer packets are NOT proof of an all-participant group conversation.

This topology was not rewritten in this pass. It requires an explicitly designed
shared SFU room (or bounded full mesh for small calls), participant lifecycle,
identity/room authorization, reconnect and real device/audio tests. Do not mark
group audio as release-ready based on the signaling results below.

Caption recognition also captures the local microphone of the participant who
enables captions. Relaying that text and translation works independently of
MeshPro on listeners, but this does not transcribe every other participant merely
because one person enabled captions. Shared caption activation/sponsorship and
audio capture consent need a separate group-session design. No Groq recognition
accuracy, actual translation inference or microphone test was performed here.

## Fixes Implemented

- Exact call-ID and known-participant checks for end, answer, ICE, restart and
  caption handling. A delayed end from an earlier call cannot end the current one.
  Authenticated same-account alternate devices remain valid for direct calls;
  server-mirrored terminal events are limited to the user's own account.
- Independent reconnect timers per participant. One connected peer no longer
  cancels another peer's recovery, and losing one peer keeps the call active while
  other connections remain. Removed peers' callbacks and duplicate terminal events
  are ignored. Late group offer generation stops after hangup or call replacement.
- Caption revisions, final-vs-partial ordering, and preservation of an existing
  translation on a duplicate text update. Different speakers remain separate even
  with the same caption ID. Late translation results cannot be sent into a new
  call or attached to a changed local phrase.
- Experimental delivery v2 now schedules/coalesces sync hints independently per
  device instead of awaiting slow socket writes in the PubSub dispatcher. Task
  count is bounded by connected devices; matching disconnect and stop cancel work.
  The SQL checkpoint remains the source of truth. Legacy raw sends are unchanged.

## Real Group Runs

PostgreSQL 16.15, Redis 8.4.2, two relay processes and synthetic Python WebSocket
clients, entirely in the E-drive lab. Feature flags are enabled only in these
isolated worker environments. Each message contains an 8 KiB synthetic payload.
Senders wait for mutation ACKs; slow readers wait 75 ms per received frame.

| Run | Participants | Messages | Slow / paused | Result |
| --- | --- | --- | --- | --- |
| `e045bda58f` | 24 | 80 | 6 / 4 | Passed; 1896 final message checks |
| `e86a32d8bf` | 48 | 100 | 12 / 8 | Passed after eight client reconnects; 4752 checks |
| `c0af3be3be` | 48 | 100 | 12 / 8 | Passed after hint dispatcher change; 4752 checks |

All include exact final-state checks after edit/delete. The final 48-client run
also waits for a fresh checkpoint on deliberate reconnect. Actual write-buffer
growth was sampled (up to 544458 bytes on the final run); slow send completion
times exceeded five seconds under event-loop load. An asyncio deadline can be
delayed by other synchronous work: this is not a hard real-time guarantee.

Final run: fast receivers reached the last message in 68.45 seconds including
all sequential send/ACK time; all receivers converged in 98.34 seconds. Before
the dispatcher change the corresponding times were 68.43 and 99.21 seconds.
These runs do NOT establish a throughput improvement. Other tests shared the
machine, the synthetic payloads are large, and CPU/SQL/sync costs remain to be
profiled. They prove convergence in this scenario, not production capacity.

The initial 48-client run `26cdbed273` timed out because deliberately paused test
clients closed on keepalive timeout and the harness did not reconnect them. That
failed report is retained. Earlier harness setup attempts used short node IDs
recognized by legacy-owner migration logic; subsequent runs use UUID node IDs.

## Calls and Captions Checked

Real signaling through the two relay workers: host invites three guests, receives
answers, one guest's caption and English translation reach host and both other
guests with revision preserved, guest departure is delivered, then another guest
receives and answers a restart offer. This uses synthetic SDP and text only.
The standalone signaling consumer has unit coverage, not a separate real media
server deployment in this lab.

## Regression Results

- Full server suite: 302 tests passed, including real PostgreSQL checks.
- Flutter full suite: 141 tests passed before the final extra alternate-device
  regression. Final targeted call suite: 13 passed after the last edits.
- Final Flutter analyzer: no issues.
- Logs: `.review/group-fanout-server-all.log`,
  `.review/group-calls-flutter-all.log`, `.review/group-calls-client-final.log`,
  `.review/group-calls-analyze-final.log`.
- Real run JSON/logs: `E:/meshchat-reliability-lab/group-runs/<run-id>/`.

No builds, production deployment or Git push were performed. Existing unrelated
worktree changes were preserved. Before rollout, resolve the group-audio blocker,
profile group sync CPU/SQL costs, and test actual devices, audio and STT.
