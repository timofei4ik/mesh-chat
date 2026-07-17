# MeshPro subscriptions

MeshPro is one paid entitlement shared by MeshChat and MeshPrivacy. Supported
activation sources are Boosty through its official private Telegram group,
Lava.top, YooKassa, and manually approved Sber orders. Boosty setup is covered
in `BOOSTY_ACTIVATION.md`; this document retains the direct payment-provider
setup.

Access is enforced on the server. A client cannot activate MeshPro by changing
local data: the relay grants time only after it authenticates a Lava webhook,
fetches the invoice from Lava again, and verifies the local order, product,
offer, buyer email, amount, currency, invoice type, status, and parent invoice.
Webhook retries are idempotent.

## 1. Back up and update the server

```bash
cd /root/mesh_messenger
cp data/server.db "data/server.db.before-lava-$(date +%F-%H%M%S)"
.venv/bin/pip install -r server/requirements.txt
```

The SQLite migration runs at startup. Existing accounts, chats, subscriptions,
and old payment orders are preserved.

## 2. Create the Lava product

In Lava.top:

1. Create a MeshPro subscription product for `199 RUB` per month.
2. Copy the product UUID and its monthly offer UUID.
3. Open `Integrations -> Public API` and create an API key for requests from
   MeshChat to Lava.
4. Generate a different key for incoming webhooks:

```bash
openssl rand -hex 32
```

5. Add two webhooks with the same URL and generated webhook key:
   - `Payment result`;
   - `Recurrent payment`.

Webhook URL:

```text
https://meshchat-losa.ru/billing/lava/webhook
```

Choose API-key authentication in Lava and paste the generated webhook key.
Do not paste Lava's outgoing API key into the webhook authentication field:
these are two different secrets.

## 3. Configure MeshPro

```bash
install -d -o root -g root -m 700 /etc/mesh-messenger
install -o root -g root -m 600 \
  server/ops/meshpro.env.example \
  /etc/mesh-messenger/meshpro.env
nano /etc/mesh-messenger/meshpro.env
```

Set at least:

```ini
MESH_LAVA_API_URL=https://gate.lava.top
MESH_LAVA_API_KEY=PASTE_LAVA_PUBLIC_API_KEY
MESH_LAVA_WEBHOOK_KEY=PASTE_YOUR_GENERATED_WEBHOOK_KEY
MESH_LAVA_PRODUCT_ID=PASTE_LAVA_PRODUCT_UUID
MESH_LAVA_OFFER_ID=PASTE_LAVA_MONTHLY_OFFER_UUID
MESH_MESHPRO_MONTHLY_PRICE=199.00
MESH_MESHPRO_MONTHLY_DAYS=30
MESH_SUBSCRIPTION_CHECKOUT_URL=https://meshchat-losa.ru/meshpro/
MESH_SUBSCRIPTION_MANAGE_URL=
```

Keep the existing WireGuard values. The checkout remains disabled unless
`MESH_WG_ENABLED=1` and `MESH_WG_ENDPOINT` are set, so the server cannot accept
money while VPN delivery is unavailable.

Attach the root-only environment file to systemd:

```ini
[Service]
EnvironmentFile=/etc/mesh-messenger/meshpro.env
```

Never put real keys in Git, `/var/www`, client builds, screenshots, or shell
commands that will be shared.

## 4. Proxy billing through Nginx

Add these locations inside the HTTPS `server` block. They must be outside the
PWA cookie gate.

```nginx
location = /meshpro {
    auth_basic off;
    return 308 /meshpro/;
}

location ^~ /meshpro/ {
    auth_basic off;
    proxy_pass http://127.0.0.1:8766;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}

location = /billing/offer {
    auth_basic off;
    proxy_pass http://127.0.0.1:8766;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}

location = /billing/checkout {
    auth_basic off;
    proxy_pass http://127.0.0.1:8766;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    client_max_body_size 4k;
}

location = /billing/lava/webhook {
    auth_basic off;
    access_log off;
    proxy_pass http://127.0.0.1:8766;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    client_max_body_size 64k;
}

location = /billing/payment-complete {
    auth_basic off;
    proxy_pass http://127.0.0.1:8766;
    proxy_set_header Host $host;
}
```

`/billing/health` should remain reachable only on localhost port `8766`.

## 5. Validate and restart

```bash
cd /root/mesh_messenger
set -a
. /etc/mesh-messenger/meshpro.env
set +a
.venv/bin/python -m server.ops.check_meshpro_readiness
nginx -t
systemctl reload nginx
systemctl daemon-reload
systemctl restart mesh-server
systemctl status mesh-server --no-pager
journalctl -u mesh-server -n 80 --no-pager -o cat
.venv/bin/python -m server.ops.check_meshpro_readiness --live
```

Useful checks:

```bash
curl -sS http://127.0.0.1:8766/billing/health
curl -sS https://meshchat-losa.ru/billing/offer
curl -I https://meshchat-losa.ru/meshpro/
wg show wg0
```

Complete one real low-value test before publishing:

1. Open MeshPro from MeshPrivacy.
2. Enter the MeshChat login and receipt email.
3. Pay through Lava.
4. Refresh MeshPro status and connect the VPN.
5. Confirm a second device gets another WireGuard peer.
6. Cancel the subscription in Lava and verify that access remains until the
   paid end date, then expires.

## Support commands

```bash
cd /root/mesh_messenger
.venv/bin/python -m server.subscription_admin status --login user
.venv/bin/python -m server.subscription_admin grant --login user --days 30
.venv/bin/python -m server.subscription_admin revoke --login user
```

Revocation removes every WireGuard peer for the MeshPro account. The relay also
reconciles expired peers at startup and every minute.
