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
