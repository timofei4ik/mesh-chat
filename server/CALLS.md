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

## Client recovery

Direct calls negotiate Opus in-band FEC and DTX on Android, Windows, iOS and
web. Standard audio starts at 40 kbit/s and HD audio at 96 kbit/s. The client
uses interval packet loss, jitter and RTT to reduce the sender cap under poor
conditions and restores quality only after several healthy samples.

Disconnected direct calls request fresh ICE servers and retry ICE restart with
a bounded 1, 3, 7 and 10 second backoff. The in-call strip and Diagnostics page
show route, codec, inbound bitrate, RTT, jitter, packet loss and the current
recovery attempt. WebRTC's jitter buffer and Opus FEC recover short gaps; old
live audio is not replayed after a long outage because doing so would increase
latency and make conversation timing unusable.

An initial `call_offer` is also queued for offline account devices for up to
45 seconds. This lets a push-woken client reconnect and receive the original
offer without resurrecting an expired call. A matching `call_end` removes the
queued offer from every device on the destination account.

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
