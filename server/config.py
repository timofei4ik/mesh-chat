import os
from pathlib import Path


HOST = os.environ.get(
    "MESH_SERVER_HOST",
    "0.0.0.0"
)

PORT = int(
    os.environ.get(
        "MESH_SERVER_PORT",
        "8765"
    )
)

DB_PATH = Path(
    os.environ.get(
        "MESH_SERVER_DB",
        "data/server.db"
    )
)

SYNC_V2_DELTA_ENABLED = os.environ.get(
    "MESH_SYNC_V2_DELTA_ENABLED",
    "0",
).strip().lower() in {"1", "true", "yes", "on"}

SYNC_V2_DELTA_TEST_ACCOUNTS = frozenset(
    login.strip().lower()
    for login in os.environ.get(
        "MESH_SYNC_V2_DELTA_TEST_ACCOUNTS",
        "",
    ).split(",")
    if login.strip()
)

SUBSCRIPTION_CHECKOUT_URL = os.environ.get(
    "MESH_SUBSCRIPTION_CHECKOUT_URL",
    ""
).strip()

SUBSCRIPTION_MANAGE_URL = os.environ.get(
    "MESH_SUBSCRIPTION_MANAGE_URL",
    ""
).strip()

SBER_PAYMENT_URL = os.environ.get(
    "MESH_SBER_PAYMENT_URL",
    ""
).strip()

BILLING_HOST = os.environ.get(
    "MESH_BILLING_HOST",
    "127.0.0.1"
).strip()

BILLING_PORT = int(
    os.environ.get(
        "MESH_BILLING_PORT",
        "8766"
    )
)

BOOSTY_TELEGRAM_API_URL = os.environ.get(
    "MESH_BOOSTY_TELEGRAM_API_URL",
    "https://api.telegram.org"
).strip().rstrip("/")

BOOSTY_TELEGRAM_BOT_TOKEN = os.environ.get(
    "MESH_BOOSTY_TELEGRAM_BOT_TOKEN",
    ""
).strip()

BOOSTY_TELEGRAM_GROUP_ID = os.environ.get(
    "MESH_BOOSTY_TELEGRAM_GROUP_ID",
    ""
).strip()

BOOSTY_TELEGRAM_OWNER_ID = os.environ.get(
    "MESH_BOOSTY_TELEGRAM_OWNER_ID",
    ""
).strip()

BOOSTY_ACTIVATION_SECRET = os.environ.get(
    "MESH_BOOSTY_ACTIVATION_SECRET",
    ""
).strip()

BOOSTY_ACTIVATION_URL = os.environ.get(
    "MESH_BOOSTY_ACTIVATION_URL",
    "https://meshchat-losa.ru/meshpro/activate"
).strip()

BOOSTY_ACTIVATION_CODE_TTL_SECONDS = max(
    60,
    int(os.environ.get("MESH_BOOSTY_CODE_TTL_SECONDS", "600"))
)

BOOSTY_KEY_DURATION_DAYS = max(
    1,
    int(os.environ.get("MESH_BOOSTY_KEY_DURATION_DAYS", "30"))
)

BOOSTY_KEY_ISSUE_INTERVAL_DAYS = max(
    1,
    int(os.environ.get("MESH_BOOSTY_KEY_ISSUE_INTERVAL_DAYS", "30"))
)

BOOSTY_SUBSCRIPTION_LEASE_HOURS = max(
    6,
    int(os.environ.get("MESH_BOOSTY_LEASE_HOURS", "36"))
)

BOOSTY_RECONCILE_INTERVAL_SECONDS = max(
    300,
    int(os.environ.get("MESH_BOOSTY_RECONCILE_SECONDS", "21600"))
)

LAVA_API_URL = os.environ.get(
    "MESH_LAVA_API_URL",
    "https://gate.lava.top"
).strip().rstrip("/")

LAVA_API_KEY = os.environ.get(
    "MESH_LAVA_API_KEY",
    ""
).strip()

LAVA_WEBHOOK_KEY = os.environ.get(
    "MESH_LAVA_WEBHOOK_KEY",
    ""
).strip()

LAVA_PRODUCT_ID = os.environ.get(
    "MESH_LAVA_PRODUCT_ID",
    ""
).strip()

LAVA_OFFER_ID = os.environ.get(
    "MESH_LAVA_OFFER_ID",
    ""
).strip()

YOOKASSA_API_URL = os.environ.get(
    "MESH_YOOKASSA_API_URL",
    "https://api.yookassa.ru/v3"
).strip().rstrip("/")

YOOKASSA_SHOP_ID = os.environ.get(
    "MESH_YOOKASSA_SHOP_ID",
    ""
).strip()

YOOKASSA_SECRET_KEY = os.environ.get(
    "MESH_YOOKASSA_SECRET_KEY",
    ""
).strip()

YOOKASSA_RETURN_URL = os.environ.get(
    "MESH_YOOKASSA_RETURN_URL",
    "https://meshchat-losa.ru/billing/payment-complete"
).strip()

YOOKASSA_WEBHOOK_SECRET = os.environ.get(
    "MESH_YOOKASSA_WEBHOOK_SECRET",
    ""
).strip()

MESHPRO_MONTHLY_PRICE = os.environ.get(
    "MESH_MESHPRO_MONTHLY_PRICE",
    os.environ.get(
        "MESH_MESHPRIVACY_MONTHLY_PRICE",
        "199.00"
    )
).strip()

MESHPRO_MONTHLY_DAYS = int(
    os.environ.get(
        "MESH_MESHPRO_MONTHLY_DAYS",
        os.environ.get(
            "MESH_MESHPRIVACY_MONTHLY_DAYS",
            "30"
        )
    )
)

AI_API_URL = os.environ.get(
    "MESH_AI_API_URL",
    "",
).strip()

AI_API_KEY = os.environ.get(
    "MESH_AI_API_KEY",
    "",
).strip()

AI_MODEL = os.environ.get(
    "MESH_AI_MODEL",
    "",
).strip()

AI_VISION_MODEL = os.environ.get(
    "MESH_AI_VISION_MODEL",
    "meta-llama/llama-4-scout-17b-16e-instruct",
).strip()

AI_TIMEOUT_SECONDS = max(
    5,
    int(os.environ.get("MESH_AI_TIMEOUT_SECONDS", "45")),
)

AI_MAX_INPUT_CHARS = max(
    500,
    int(os.environ.get("MESH_AI_MAX_INPUT_CHARS", "4000")),
)

AI_MAX_SUMMARY_CHARS = max(
    2000,
    int(os.environ.get("MESH_AI_MAX_SUMMARY_CHARS", "12000")),
)

AI_MAX_IMAGE_BYTES = max(
    256 * 1024,
    int(os.environ.get("MESH_AI_MAX_IMAGE_BYTES", str(2 * 1024 * 1024))),
)

AI_TRANSCRIPTION_API_URL = os.environ.get(
    "MESH_AI_TRANSCRIPTION_API_URL",
    "",
).strip()

if not AI_TRANSCRIPTION_API_URL and AI_API_URL:
    if "/chat/completions" in AI_API_URL:
        AI_TRANSCRIPTION_API_URL = AI_API_URL.replace(
            "/chat/completions",
            "/audio/transcriptions",
        )
    else:
        AI_TRANSCRIPTION_API_URL = (
            AI_API_URL.rstrip("/") + "/audio/transcriptions"
        )

AI_TRANSCRIPTION_MODEL = os.environ.get(
    "MESH_AI_TRANSCRIPTION_MODEL",
    "whisper-large-v3-turbo",
).strip()

AI_MAX_AUDIO_BYTES = max(
    256 * 1024,
    int(os.environ.get("MESH_AI_MAX_AUDIO_BYTES", str(8 * 1024 * 1024))),
)

SMTP_HOST = os.environ.get("MESH_SMTP_HOST", "").strip()
SMTP_PORT = int(os.environ.get("MESH_SMTP_PORT", "587"))
SMTP_USERNAME = os.environ.get("MESH_SMTP_USERNAME", "").strip()
SMTP_PASSWORD = os.environ.get("MESH_SMTP_PASSWORD", "")
SMTP_FROM_EMAIL = os.environ.get("MESH_SMTP_FROM_EMAIL", SMTP_USERNAME).strip()
SMTP_FROM_NAME = os.environ.get("MESH_SMTP_FROM_NAME", "MeshChat").strip()
SMTP_USE_TLS = os.environ.get("MESH_SMTP_USE_TLS", "1").strip().lower() in {
    "1", "true", "yes", "on"
}
SMTP_USE_SSL = os.environ.get("MESH_SMTP_USE_SSL", "0").strip().lower() in {
    "1", "true", "yes", "on"
}
EMAIL_2FA_SECRET = os.environ.get(
    "MESH_EMAIL_2FA_SECRET",
    os.environ.get("MESH_SERVER_TOKEN", ""),
).strip()

# Keep installed clients on the legacy handshake during the staged rollout.
# Set this to 0 after the supported client versions all advertise email 2FA.
EMAIL_2FA_LEGACY_CLIENTS_ALLOWED = os.environ.get(
    "MESH_EMAIL_2FA_LEGACY_CLIENTS_ALLOWED",
    "1",
).strip().lower() in {"1", "true", "yes", "on"}
EMAIL_2FA_CODE_TTL_SECONDS = max(
    120,
    int(os.environ.get("MESH_EMAIL_2FA_CODE_TTL_SECONDS", "600")),
)
EMAIL_2FA_RESEND_SECONDS = max(
    30,
    int(os.environ.get("MESH_EMAIL_2FA_RESEND_SECONDS", "60")),
)
EMAIL_2FA_MAX_ATTEMPTS = max(
    3,
    int(os.environ.get("MESH_EMAIL_2FA_MAX_ATTEMPTS", "6")),
)

WIREGUARD_ENABLED = os.environ.get(
    "MESH_WG_ENABLED",
    ""
).strip().lower() in (
    "1",
    "true",
    "yes",
    "on"
)

WIREGUARD_INTERFACE = os.environ.get(
    "MESH_WG_INTERFACE",
    "wg0"
).strip()

WIREGUARD_COMMAND = os.environ.get(
    "MESH_WG_COMMAND",
    "wg"
).strip()

WIREGUARD_SERVER_PUBLIC_KEY = os.environ.get(
    "MESH_WG_SERVER_PUBLIC_KEY",
    ""
).strip()

WIREGUARD_ENDPOINT = os.environ.get(
    "MESH_WG_ENDPOINT",
    ""
).strip()

WIREGUARD_NETWORK = os.environ.get(
    "MESH_WG_NETWORK",
    "10.77.0.0/24"
).strip()

WIREGUARD_SERVER_ADDRESS = os.environ.get(
    "MESH_WG_SERVER_ADDRESS",
    "10.77.0.1"
).strip()

WIREGUARD_DNS = os.environ.get(
    "MESH_WG_DNS",
    "1.1.1.1, 1.0.0.1"
).strip()

WIREGUARD_ALLOWED_IPS = os.environ.get(
    "MESH_WG_ALLOWED_IPS",
    "0.0.0.0/0, ::/0"
).strip()

WIREGUARD_KEEPALIVE = int(
    os.environ.get(
        "MESH_WG_KEEPALIVE",
        "25"
    )
)

WIREGUARD_PEER_DIR = Path(
    os.environ.get(
        "MESH_WG_PEER_DIR",
        "/var/lib/mesh-messenger/wireguard-peers"
    )
)

MESHPRIVACY_MIN_APP_VERSION = os.environ.get(
    "MESH_MESHPRIVACY_MIN_APP_VERSION",
    "1.3.0",
).strip()

SERVER_TOKEN = os.environ.get(
    "MESH_SERVER_TOKEN",
    ""
).strip()

WEB_PUSH_VAPID_PRIVATE_KEY = os.environ.get(
    "MESH_WEB_PUSH_VAPID_PRIVATE_KEY",
    ""
).strip()

WEB_PUSH_VAPID_PUBLIC_KEY = os.environ.get(
    "MESH_WEB_PUSH_VAPID_PUBLIC_KEY",
    ""
).strip()

WEB_PUSH_VAPID_SUBJECT = os.environ.get(
    "MESH_WEB_PUSH_VAPID_SUBJECT",
    "mailto:admin@meshchat-losa.ru"
).strip()

FIREBASE_CREDENTIALS = os.environ.get(
    "MESH_FIREBASE_CREDENTIALS",
    ""
).strip()

FIREBASE_PROJECT_ID = os.environ.get(
    "MESH_FIREBASE_PROJECT_ID",
    ""
).strip()

REQUIRE_LOGIN = os.environ.get(
    "MESH_SERVER_REQUIRE_LOGIN",
    ""
).strip().lower() in (
    "1",
    "true",
    "yes",
    "on"
)

PASSWORD_ITERATIONS = 200_000
