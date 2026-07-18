# Sync v2 acceptance matrix

Every row is required before `sync_v2_delta` can be enabled by default.

| ID | Scenario | Required assertion |
| --- | --- | --- |
| ID-01 | Two devices, one account | One user identity; independent monotonic device cursors; no duplicate member or reaction. |
| ID-02 | Username/profile/device change | Existing chats, ownership, reactions, and history remain attached to the same account. |
| OP-01 | Retry one mutation | One authoritative row, one event per affected account, duplicate successful ACK, no second live delivery. |
| OP-02 | Group fanout retry | One logical operation with destination-specific ACKs; no duplicated group message. |
| OP-03 | Permanent rejection | Unauthorized owner/admin/delete operation is not stored or retried. |
| TX-01 | Crash between state and journal commit | State row, tombstone, journal event, and processed mutation marker are committed together or all rolled back. |
| EV-01 | Event ordering | Event IDs increase; gaps are allowed; payload order is deterministic. |
| EV-02 | Duplicate event | Applying the same event twice leaves identical state and counters. |
| EV-03 | Cursor ACK | ACK never moves backward and cannot move ahead of the account journal. |
| EV-04 | Interrupted delta | No cursor advance; reconnect replays the complete old-cursor range. |
| EV-05 | Event during snapshot | Snapshot cursor excludes the concurrent event; next delta includes it. |
| EV-06 | Unsafe or pruned range | Server sends a full snapshot, never a partial delta. |
| DEL-01 | Delete for everyone while recipient chat is open | Recipient applies the live tombstone immediately and it stays deleted after reconnect/reinstall. |
| DEL-02 | Delete while recipient is offline | Snapshot or delta tombstone removes the object and related media/reactions/pins. |
| DEL-03 | Group/channel delete | Only owner can delete; all members lose it live and after reconnect. |
| DEL-04 | Leave group/channel | Membership and live location are removed server-side and never restored by stale client cache. |
| GRP-01 | Add/remove member | Server list is authoritative on all online devices and after relogin. |
| GRP-02 | Owner/admin transfer | Only current owner can transfer ownership; roles resolve by account, not device node. |
| GRP-03 | New channel member | Existing posts, comments, reactions, and permitted media are present immediately. |
| REA-01 | Repeated reaction | Same user/device retry creates one reaction. |
| REA-02 | Same account, second device | Same reaction still creates one account reaction. |
| MSG-01 | Offline send and reconnect | Outbox survives process restart; ACK removes only committed destination entry. |
| MSG-02 | Edit and delete live | Open recipient view updates immediately; reconnect matches server state. |
| MSG-03 | Channel comment | Comment remains a comment, never becomes a post, including retry and relogin. |
| MED-01 | Photo/file/sticker | Metadata and payload restore on another device; checksum and size match. |
| MED-02 | Transfer interruption | Upload resumes missing chunks only; receiver gets one completed item. |
| SEC-01 | Secret chat reinstall | Thread identity, encrypted text, photo, and file recover or fail explicitly; no empty phantom message. |
| SNAP-01 | Fresh install | Full snapshot produces the same state as the authoritative database. |
| SNAP-02 | Relogin with cache | Snapshot reconciliation removes stale local groups/messages and preserves drafts/preferences. |
| COMP-01 | Legacy client | Protocol v5 client without v2 flags keeps working and never receives v2-only packets. |
| FAIL-01 | Socket closes mid-sync | No partial cursor commit; reconnect is safe. |
| FAIL-02 | Server restart after mutation commit | Retry is deduplicated and ACKed; event remains available. |
| OBS-01 | Backup/restore | Restored DB preserves accounts, roles, tombstones, journal IDs, cursor floor, and file references. |

## Current rollout status

- Existing integration tests cover authoritative full snapshots, live direct and
  group edit/delete, owner-only group/channel deletion, member leave, channel
  history/comments/files, sticker libraries, stories, durable offline ACK,
  mutation deduplication, and resumable file transfer.
- Contract tests cover event deduplication, per-device cursor monotonicity,
  tombstone classification, account-scoped reaction uniqueness, TX-01
  rollback at both durability boundaries, explicit retained-floor fallback,
  bounded delta planning, interrupted replay, snapshot boundary events, and an
  exhaustive delta-safe/shadow-reducer type check.
- State, journal events, and the processed outbox marker now commit in one
  transaction before ACK or live routing. Delta streaming and client-side
  validation are capability-gated. Delta remains disabled for ordinary
  accounts by default, while `MESH_SYNC_V2_DELTA_TEST_ACCOUNTS` enables a
  normalized login allowlist and `MESH_SYNC_V2_DELTA_ENABLED=1` enables all
  capable accounts.
- Snapshot/delta shadow comparison now covers direct and group message create,
  edit, reaction, pin, and delete operations. A deterministic two-device soak
  runs 240 mutation rounds with independent sync checkpoints, duplicate
  delivery attempts, edits, reactions from two devices of one account, and
  tombstones; every checkpoint must equal a fresh authoritative snapshot.
- Binary file completion, sticker-library updates, scheduled-message changes,
  chat preferences, and MeshPro preferences now advance the journal with an
  explicit snapshot-required event. Incomplete file chunks do not advance a
  cursor. This prevents an apparently successful empty delta from hiding state
  that only exists in the authoritative snapshot.
- Remaining rollout work is live canary observation, owner/admin transfer
  coverage, backup/restore validation, and then changing the global default.
