# File Transfer v2

File Transfer v2 makes MeshChat uploads durable and resumable without putting
large file chunks in the offline packet queue.

## Negotiation

The client advertises `supports_file_transfer_v2: true` in `server_hello`.
The server enables the protocol with `capabilities.file_transfer_v2: true` in
`server_welcome`. Older clients continue to use the legacy `file_chunk` path.

## Upload

Each `file_chunk` carries a stable `transfer_id`, logical `operation_id`,
`file_sha256`, `file_size`, `chunk_size_bytes`, `chunk_index`, and
`total_chunks`. The server validates the immutable metadata, writes the chunk
atomically to disk, commits its receipt to SQLite, and only then sends a
`file_chunk_ack`.

`received_ranges` contains inclusive chunk ranges, for example
`[[0, 3], [6, 6]]`. A reconnecting client resends only indexes outside these
ranges. The current client keeps at most four chunks in flight and retries an
unacknowledged window after four seconds.

## Completion and restore

After all chunks arrive, the server streams them into a permanent binary file
and verifies both byte count and SHA-256. A checksum failure returns
`ok: false`, `retryable: true`, and `reset: true`; the client restarts that
transfer from chunk zero.

The durable `server_files` record stores the binary path, checksum, and size.
Online recipients receive one completed stream. Offline recipients do not get
large chunks in `offline_packets`; their normal account sync streams the file
from disk when they reconnect.

## Cancellation and cleanup

`file_transfer_cancel` removes an incomplete transfer and its staged chunks.
Incomplete sessions expire after seven days. Completed receipt records expire
after thirty days, while the permanent payload remains tied to its
`server_files` message and is removed when that message or group is deleted.
