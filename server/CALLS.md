# Calls and TURN

Call signaling is handled by `server_calls.py`. Signaling packets are
ephemeral and do not enter message history or Sync v2. Installed clients that
do not request ICE configuration continue to use their built-in public STUN
servers.

## Environment

```text
MESH_TURN_STUN_URLS=stun:meshchat-losa.ru:3478
MESH_TURN_URLS=turn:meshchat-losa.ru:3478?transport=udp,turn:meshchat-losa.ru:3478?transport=tcp
MESH_TURN_SHARED_SECRET=<same random secret as coturn static-auth-secret>
MESH_TURN_CREDENTIAL_TTL_SECONDS=3600
```

The relay returns time-limited credentials generated with the coturn REST API
HMAC formula. The shared secret must remain on the server and must never be
included in a client build.

## Network

Open UDP/TCP 3478 and UDP 49160-49260. If TLS TURN is enabled, also open TCP
5349 and add the certificate paths shown in
`ops/coturn/turnserver.conf.example`.

## Rollout

1. Install coturn and apply the template.
2. Put the same generated secret in coturn and the MeshChat service environment.
3. Restart coturn and MeshChat.
4. Verify UDP and TCP relay candidates from two devices on different networks.
5. Keep the public STUN entries as fallback during rollout.
