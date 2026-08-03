# Media Delivery v2

Media Delivery v2 keeps file metadata in WebSocket snapshots and transfers file
bytes over an authenticated HTTP endpoint. Native clients advertise the
`media_delivery_v2` capability during login. Older clients and the web client
continue to receive the legacy WebSocket chunk stream.

## Download flow

1. The server sends a `file_manifest` containing the file id, size, checksum,
   content type, and encryption metadata.
2. The client sends `media_download_request` over its authenticated WebSocket.
3. The server verifies that the account is a direct participant or a current
   member of the target group and returns a short-lived, file-scoped bearer
   token.
4. The client downloads `/media/v2/{file_id}` and keeps interrupted bytes in a
   persistent `.part` file. The next attempt resumes with an HTTP `Range`
   request and rejects a mismatched `Content-Range` rather than joining bytes
   from different representations.
5. The client verifies size and SHA-256 as a stream before atomically moving
   the file into its local LRU cache. A corrupt partial is discarded and the
   transfer is retried once from byte zero. Group payloads are decrypted only
   after the encrypted bytes pass integrity verification. Abandoned partials
   are removed after seven days.

Tokens expire after ten minutes by default. A shared signing secret allows the
standalone media service to validate tokens issued by any Chat/Sync worker.
The public endpoint never accepts an account name or password.

## Configuration

The standalone service is started with `python -m server.media_service`. The
production unit binds `127.0.0.1:8777` and can be configured with:

- `MESH_MEDIA_HTTP_HOST`
- `MESH_MEDIA_HTTP_PORT`
- `MESH_MEDIA_PUBLIC_BASE_URL`
- `MESH_MEDIA_TOKEN_TTL_SECONDS`
- `MESH_MEDIA_SIGNING_SECRET`
- `MESH_MEDIA_OBJECT_ROOT`

Completed uploads are stored by SHA-256 in the configured object root. Expose
the service through nginx with `nginx_media_v2.conf`. Keep it bound to loopback
so token validation cannot be bypassed through a second public listener.

## Observability

`/media/health` includes a point-in-time metrics object. `/media/metrics` and
`/metrics` expose the same counters in Prometheus text format, including active
downloads, range requests, response bytes, authorization failures, invalid
ranges, storage kind, and server errors. Alert on sustained authorization or
server errors rather than individual interrupted range requests: resumable
clients deliberately reconnect after network loss.
