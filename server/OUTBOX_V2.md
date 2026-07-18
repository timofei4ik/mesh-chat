# MeshChat Outbox v2

Outbox v2 makes durable client mutations retryable without applying the same
operation twice. It is capability-gated so older servers and clients continue
to interoperate.

## Negotiation

The client adds this field to `client_hello`:

```json
{"supports_mutation_ack": true}
```

The server advertises support in `server_welcome`:

```json
{"capabilities": {"mutation_ack": true}}
```

Until `server_welcome` arrives, a capable client keeps durable mutations in its
local outbox. If the server does not advertise the capability, each queued
packet is sent once and removed for compatibility with the legacy protocol.

## Durable mutation packet

The client persists the complete packet before sending and adds:

```json
{
  "operation_id": "chat_message:message-id",
  "outbox_id": "chat_message:message-id|destination-node|"
}
```

`operation_id` identifies one logical user action. Group fanout packets share
that value. `outbox_id` identifies one destination-specific delivery and is the
server deduplication key for the authenticated account.

## Acknowledgement

After the mutation has been committed to authoritative storage and written to
the Sync v2 journal, the server replies:

```json
{
  "type": "mutation_ack",
  "ok": true,
  "duplicate": false,
  "outbox_id": "chat_message:message-id|destination-node|",
  "operation_id": "chat_message:message-id",
  "packet_type": "chat_message",
  "packet_id": "message-id"
}
```

The client removes only the acknowledged destination entry. It marks the
logical operation complete after no entries with the same `operation_id`
remain. A retry of an already committed `outbox_id` receives the same successful
ACK with `duplicate: true` and is not routed again.

Permanent validation or storage rejection uses `ok: false` and a `reason`.
That entry is removed instead of being retried forever, and the local message is
marked failed.

## Persistence and retries

Native clients store the queue in SQLite. Web clients use SharedPreferences.
The partition key is normalized server URL plus account login; passwords and
tokens are not included. Pending entries are replayed after reconnect only once
capability negotiation has completed.

The processed-mutation marker is committed immediately after the authoritative
mutation commit. A process crash in that narrow interval can repeat a retry, so
all currently enabled Outbox mutation handlers remain idempotent (upsert,
set-like reaction updates, or delete operations).

## Scope

Outbox v2 currently covers messages and the main edit, delete, pin, reaction,
group, story, and sticker-library mutations. It intentionally excludes typing,
presence, calls, diagnostics, request/response API packets, and `file_chunk`.
Large file chunks need a separate file-backed queue so binary payloads are not
duplicated in SQLite or browser preferences.
