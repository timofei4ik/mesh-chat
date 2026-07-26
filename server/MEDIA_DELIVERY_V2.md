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
4. The client downloads `/media/v2/{file_id}` and resumes an interrupted
   transfer with an HTTP `Range` request.
5. The client verifies size and SHA-256 before atomically moving the file into
   its local LRU cache. Group payloads are decrypted only after the encrypted
   bytes pass integrity verification.

Tokens expire after ten minutes by default and are invalidated when the server
restarts. The public endpoint never accepts an account name or password.

## Configuration

The worker defaults to `127.0.0.1:8767` and can be configured with:

- `MESH_MEDIA_HTTP_HOST`
- `MESH_MEDIA_HTTP_PORT`
- `MESH_MEDIA_PUBLIC_BASE_URL`
- `MESH_MEDIA_TOKEN_TTL_SECONDS`

Expose the worker through nginx with `nginx_media_v2.conf`. Keep the worker
bound to loopback so token validation cannot be bypassed through a second
public listener.
