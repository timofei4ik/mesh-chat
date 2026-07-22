# MeshChat email two-factor authentication

Email verification is required by MeshChat clients that advertise the
`supports_email_2fa` capability. New accounts verify an address before the
account is created. Existing accounts are stopped at the email binding screen
until they verify an address.

Configure these values in the root-only systemd environment file:

```env
MESH_EMAIL_2FA_SECRET=REPLACE_WITH_A_LONG_RANDOM_VALUE
MESH_SMTP_HOST=smtp.example.com
MESH_SMTP_PORT=587
MESH_SMTP_USERNAME=meshchat@example.com
MESH_SMTP_PASSWORD=REPLACE_WITH_THE_MAILBOX_PASSWORD
MESH_SMTP_FROM_EMAIL=meshchat@example.com
MESH_SMTP_FROM_NAME=MeshChat
MESH_SMTP_USE_TLS=1
MESH_SMTP_USE_SSL=0
```

Generate the HMAC secret with `openssl rand -hex 32`. Never commit the real
secret or SMTP password.

During the rollout, clients without the email capability keep using the old
handshake. After supported client versions have been distributed, require the
new protocol without rebuilding clients:

```env
MESH_EMAIL_2FA_LEGACY_CLIENTS_ALLOWED=0
```

Restart the server after changing its environment. Keep the flag enabled until
old installations have had enough time to update; disabling it prevents old
clients from logging in or registering.
