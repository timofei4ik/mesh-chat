# MeshPro keys through Boosty and Telegram

Boosty's official Telegram bot keeps a private group synchronized with paid
subscribers. The MeshPro bot verifies membership in that group and issues one
transferable, one-time MeshPro key per paid month.

## Key model

- Key format: `MPR-XXXX-XXXX-XXXX-XXXX-XXXX`.
- The alphabet excludes ambiguous `0/O` and `1/I` characters.
- Only an HMAC-SHA256 digest is stored in SQLite.
- A key is not tied to the Telegram account that received it and may be gifted.
- A key can be redeemed only once.
- Each redeemed key adds its duration after the current MeshPro period, so
  several keys stack like prepaid Steam keys.
- A subscriber receives at most one 30-day key during each 30-day issuance
  interval. Leaving and rejoining the group does not reset the interval.
- Issued access is prepaid and is not revoked when Boosty membership ends.
  Membership only controls whether another monthly key may be issued.
- The bot owner can create gift keys for 1, 3, 6, or 12 months with `/gift`.
- MeshChat credentials are checked with the existing password hash; the
  submitted password is never stored or logged.

## Initial setup

1. Create the MeshPro Telegram bot with `@BotFather`.
2. Create a private Telegram supergroup for paid MeshPro subscribers.
3. Connect Boosty's official `@boosty_to_bot` to that group and map the paid
   MeshPro tier. Boosty will add active subscribers and remove expired ones.
4. Add the MeshPro bot to the group as an administrator so `getChatMember`
   checks are available.
5. Put the settings below in `/etc/mesh-messenger/meshpro.env` and restart the
   relay.
6. Open `https://meshchat-losa.ru/meshpro/activate` to redeem a key.

Generate the activation secret on the server:

```bash
openssl rand -hex 32
```

Required environment values:

```dotenv
MESH_BOOSTY_TELEGRAM_BOT_TOKEN=123456789:telegram-token
MESH_BOOSTY_TELEGRAM_GROUP_ID=-1001234567890
MESH_BOOSTY_TELEGRAM_OWNER_ID=123456789
MESH_BOOSTY_ACTIVATION_SECRET=64-hex-characters
MESH_BOOSTY_ACTIVATION_URL=https://meshchat-losa.ru/meshpro/activate
MESH_BOOSTY_KEY_DURATION_DAYS=30
MESH_BOOSTY_KEY_ISSUE_INTERVAL_DAYS=30
MESH_BOOSTY_RECONCILE_SECONDS=21600
```

Add the Nginx locations from `server/ops/nginx-meshpro-boosty.conf` outside
the PWA cookie gate. The activation endpoint has its own per-IP rate limit.

## Subscriber flow

1. Buy MeshPro on Boosty and join the private group through Boosty.
2. Open the MeshPro Telegram bot and send `/start` once.
3. The bot sends a key automatically when one is due. `/code` requests the due
   key immediately; it cannot bypass the monthly interval.
4. Redeem the key for any MeshChat account on the activation page.

Bot commands:

- `/code` issues the monthly key if its interval has elapsed.
- `/status` checks membership and shows when the next key is available.
- `/gift` lets only the configured Telegram user create a 14-day or
  1/3/6/12-month gift key. `/gift 14d` creates the two-week key. Telegram must
  also report that user as the group creator. If
  `MESH_BOOSTY_TELEGRAM_OWNER_ID` is missing, gift-key issuance is disabled.
- `/groupid` prints the group ID for a group administrator.

The official Boosty bot does not provide this project with a custom per-user
purchase-code API. Group membership is therefore the payment proof; the key
issued by the MeshPro bot is the transferable activation key.
