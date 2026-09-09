# Rich messages: 1.1.0 (203)

Entry point: chat attachment menu -> Rich message. Available for internet chats
and local Saved Messages, not Bluetooth. Existing formatted messages reopen in
the same editor. Drafts are scoped to the server, account, chat and edited message.

## Storage and compatibility

- `message` contains the readable text fallback; `rich_content` contains a
  versioned, validated insert-only document encrypted using the chat's existing
  text encryption. Clients bind the fallback to the document before rendering.
- SQLite and PostgreSQL history, full snapshots, delta sync and edits preserve
  `rich_content`. PostgreSQL migration: `017_rich_messages.sql`.
- Deploy the server support before enabling use between clients. The welcome
  capability is `rich_messages_v1`. An older server cannot receive Rich content:
  durable offline mutations wait for a capable server instead of losing styles.
- A document is limited to 192 KiB of JSON and 60,000 fallback characters.
  The encrypted envelope limit on the server is 768 KiB.
- Unsupported/corrupt formatting falls back to ordinary text, never raw JSON.

## Media

Photo/video, audio and file picker actions stage local payloads until Send. The
editor supports up to 16 staged files / 128 MiB per draft, 64 MiB per file.
File paths and raw bytes do not enter the Rich document. Draft payload storage is
the existing native file store or IndexedDB on web.

Each attachment has a stable file-message ID and uses the existing durable file
transfer, media history and download authorization. Rich clients display these
file records inside their owning document; older clients can still show the
readable fallback and ordinary file records. Different sender IDs cannot hide
one another's attachment records. File transfers can complete after the text:
the document shows a placeholder while waiting.

Retries reuse staged file IDs. Forwarding and saving to another chat copy the
media and rewrite references, rather than retaining inaccessible references to
the source chat. Removing a block from a sent document removes its now-unused
owned file record. Deleting a document also deletes its unshared attachments;
local-only deletion remains local. Cache trimming retains referenced file
metadata alongside retained documents.

Video and general files use the existing file-opening flow. Photos preview in
the chat; audio uses the existing player. Drafts themselves are local, not synced
between devices. The AI action uses the existing server AI provider and requires
an explicit instruction and review; no Cocoon integration is implied.

## Release verification

Run Flutter analysis and tests, especially `rich_message_test.dart`,
`rich_attachments_test.dart`, `chat_cache_integrity_test.dart`,
`mesh_socket_resilience_test.dart` and `chat_design_experiment_test.dart`.
Server coverage is in `server/tests/test_rich_messages.py` and sync/persistence
tests. Real-device iOS Liquid Glass validation is still required; Windows cannot
validate UIKit appearance.

Manual checks before publication: send mixed text/media between two updated
clients; reconnect both; reload history; edit and remove a block; forward to a
different chat; delete locally and for everyone; retry a disconnected upload.
Release 1.1.0+207 targets Windows, Android and Web. iOS is built separately
through Codemagic. Building a client alone never deploys the server.
AI drafting requires the server welcome capability `ai_compose_v1`; clients
show a server-upgrade message rather than submitting to unsupported servers.

The editor opens over its conversation and reuses the chat background. Tables
support row/column removal, block movement and text insertion before/after the
block. Sent tables fit available width or expose a horizontal scrollbar.
Trailing empty paragraphs are hidden only in the read view; stored content is
unchanged. Editor focus and cursor placement around blocks have regression tests.
