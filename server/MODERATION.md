# MeshChat moderation console

The moderation console is a separate web service. It is disabled until both
authentication secrets are configured.

Generate the password hash:

```powershell
python server/ops/create_moderation_password.py
```

Configure the service environment:

```text
MESH_MODERATION_ADMIN_PASSWORD_HASH=scrypt$...
MESH_MODERATION_SESSION_SECRET=<at least 32 random bytes>
MESH_MODERATION_ADMIN_ID=mesh-admin
MESH_MODERATION_HTTP_HOST=127.0.0.1
MESH_MODERATION_HTTP_PORT=8768
```

Generate a session secret without putting it into shell history:

```powershell
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Expose `/admin/moderation` through HTTPS in the reverse proxy. Do not expose
port 8768 directly. A ready location snippet is in
`server/ops/nginx-moderation.conf`. Reports contain only content explicitly
submitted by the reporting user. Every decision is appended to
`moderation_actions`.

The console supports dismissal, escalation, server-authoritative content
hiding, warnings, temporary account restrictions and account blocks. Content
hiding emits the same Sync v2 tombstones as user deletion, so open clients and
reconnecting devices converge on the same state. Account sanctions are stored
separately from decisions and reversible sanctions can be revoked without
rewriting the audit log. A hidden item is permanently deleted and is therefore
not reversible.
