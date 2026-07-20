# MeshChat Sync v2 contract

Status: draft, capability-gated, protocol v5 compatible.

The delta capability is implemented behind rollout controls. It remains
disabled for ordinary accounts by default, can be enabled for a normalized
comma-separated login allowlist with `MESH_SYNC_V2_DELTA_TEST_ACCOUNTS`, and
can later be enabled globally with `MESH_SYNC_V2_DELTA_ENABLED=1`.

Sync v2 is the reliability boundary between authoritative server state and
device caches. A device cache is disposable. The server database, event
journal, and durable file store are authoritative.

## Identity invariants

1. A registered account has one immutable `user_id`. During the protocol v5
   migration the normalized account login is the canonical persisted user ID.
   `node_id` identifies one installation only and must never grant ownership,
   create another group member, or create another reaction for the same user.
2. Public username, display name, avatar, and device IDs are mutable profile or
   device properties. They never identify message ownership.
3. A direct conversation has one canonical participant pair plus `chat_kind`
   and `chat_id`. A group or channel has one immutable `group_id`.
4. Group owner and administrator roles belong to accounts. Wire packets may
   contain representative node IDs for protocol v5 clients, but the server
   resolves and validates their account identity before committing a change.
5. A user can contribute at most one identical reaction to one message.
   Replaying the operation from another device is a no-op.

## Mutation invariants

Every durable user action has a stable `operation_id`. Retries, reconnects,
and group fanout keep the same `operation_id`. Each destination delivery has a
stable `outbox_id`.

The server follows this order:

1. authenticate the connection and replace `source_node` with the authenticated
   device ID;
2. validate ownership and permissions against authoritative database state;
3. begin one database transaction;
4. persist the mutation or tombstone, account event-journal rows, and the
   processed `outbox_id` marker inside that transaction;
5. commit all three durability records together, or roll all of them back;
6. return `mutation_ack`;
7. route the committed event to online devices.

A repeated `outbox_id` returns a successful ACK with `duplicate: true` and is
not routed again. Validation failures return a permanent negative ACK. A client
does not retry a permanent failure forever.

## Event journal

Each account has a logical ordered event stream backed by `sync_events`.
`event_id` is globally increasing, so gaps inside one account stream are valid.
For one account, `(operation_id, packet_type)` is unique.

An event envelope is:

```json
{
  "event_id": 43,
  "operation_id": "message_delete:message-123",
  "packet_type": "message_delete",
  "tombstone": true,
  "requires_snapshot": false,
  "payload": {
    "type": "message_delete",
    "message_id": "message-123"
  }
}
```

Delete event types are tombstones. A tombstone remains in the journal after the
deleted object disappears from current-state tables. Clients apply tombstones
idempotently even when the target is already absent.

An event is marked `requires_snapshot` when its complete authoritative payload
cannot be represented in the journal, for example a binary body, large avatar,
or unsupported mutation type. A reconnect that crosses such an event receives
a snapshot instead of a partial delta.

## Capability negotiation

Legacy protocol v5 behavior remains available.

The client hello may advertise:

```json
{
  "supports_sync_v2": true,
  "supports_sync_v2_delta": true,
  "sync_cursor": 42,
  "supports_offline_packet_ack": true,
  "supports_mutation_ack": true
}
```

The server advertises each capability independently. A server never sends a
delta unless both sides advertise `sync_v2_delta`. During rollout, clients that
only advertise `sync_v2` continue receiving an authoritative snapshot with a
cursor.

## Snapshot flow

A new installation, cursor `0`, invalid cursor, pruned cursor, journal gap, or
`requires_snapshot` event uses a snapshot.

1. Capture account journal cursor `C`.
2. Build current authoritative state.
3. Send `server_sync` with `sync_v2.mode = snapshot` and cursor `C`.
4. Stream referenced sticker and file payloads.
5. Send `server_sync_done` with cursor `C`.
6. Persist and ACK cursor `C` only after the client has applied the complete
   snapshot and durable media payloads.

Events committed after `C` are not covered by that snapshot. They are delivered
live and remain available after `C` on the next reconnect.

## Delta flow

Delta is enabled only after every event in `(client_cursor, target_cursor]` is
available and delta-safe.

1. Capture target cursor `T`.
2. Send `server_sync_delta_begin` with source cursor, target cursor, sync ID,
   event count, and `event_digest_sha256` over the canonical event envelopes.
3. Send ordered `server_sync_delta_event` packets. The client rejects a changed
   sync ID, non-increasing event ID, event above `T`, or malformed envelope.
4. Send `server_sync_done` with `sync_v2.mode = delta`, cursor `T`, and the same
   event digest. The client recalculates the digest before applying anything.
5. Apply events in order. Persist and ACK `T` only after every handler succeeds.

If the socket closes before step 5, the old cursor is retained. Reconnecting
replays the same range. Applying any event more than once must be safe.

Live events received while a delta is in progress are buffered until the delta
finishes, then applied in event order. A client never advances a cursor based on
a live packet without a completed sync boundary.

## Local cache integrity and repair

The client stores a SHA-256 digest of the complete canonical chat cache beside
each durable sync cursor. A cursor is usable only when the digest, digest
version, and row count match the current cache. Each cache replacement is a
single SQLite transaction and removes rows absent from the authoritative state.

When the cache digest is absent, malformed, or mismatched, the client discards
only the derived chat cache and its cursor. Mutation and file-transfer outboxes
are preserved. The next connection starts at cursor zero and requests a fresh
authoritative snapshot, preventing damaged local state from becoming a server
mutation or silently hiding journal events.

## Cursor rules

- Cursors are scoped by normalized server URL and account, then acknowledged
  independently per device.
- Stored cursors only move forward.
- A cursor ahead of the account journal is rejected and forces a snapshot.
- Server pruning is allowed only below the minimum cursor required by active
  devices and backup policy. The retained floor is explicit; it is not inferred
  from gaps in globally allocated event IDs.
- Cursor ACK is not proof that an event was merely received. It means all state
  and durable payloads through that event are committed locally.

## Durable offline packets

For clients with `supports_offline_packet_ack`, non-snapshot queued events carry
`_offline_queue_id` and remain in SQLite until the handler succeeds and the
client sends `offline_packet_ack`. A disconnect before ACK causes redelivery.
Legacy clients keep the old send-and-delete behavior.

Authoritative state mutations covered by snapshot or delta must not also remain
forever in the offline queue. Typing, calls, and other transient events are not
part of the account snapshot.

## Rollout gates

1. Ship journal, mutation ACK, durable offline ACK, and cursor persistence while
   continuing to send snapshots.
2. Pass every case in `SYNC_V2_TEST_MATRIX.md` with snapshot fallback enabled.
3. Enable `sync_v2_delta` for test accounts only.
4. Compare snapshot and reconstructed delta state in shadow mode.
5. Enable delta gradually. Any validation failure falls back to snapshot and is
   recorded in diagnostics.

The two rollout variables are intentionally independent:

```text
MESH_SYNC_V2_DELTA_TEST_ACCOUNTS=alice,bob
MESH_SYNC_V2_DELTA_ENABLED=0
```

enables delta only for `alice` and `bob`. Setting
`MESH_SYNC_V2_DELTA_ENABLED=1` enables it for every capable client and makes
the allowlist redundant. A client never receives a delta for an unsafe event,
an invalid or pruned cursor, a journal range above the event limit, or an event
without a matching shadow reducer; those cases automatically use a snapshot.

The shadow reducer is deliberately exhaustive: the test suite asserts that
the set of event types declared delta-safe exactly matches the set implemented
by the reducer. Deterministic mutation tests compare `snapshot + delta` with a
fresh authoritative snapshot, and the two-device soak repeats that comparison
through reconnect-style checkpoints, duplicate packets, edits, reactions, and
deletes.

No client or server should infer successful synchronization from a WebSocket
connection alone.
