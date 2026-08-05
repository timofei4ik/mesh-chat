"""Short-lived access grants for the optional LiveKit SFU."""

import base64
import hashlib
import hmac
import json
import time
import uuid


def _base64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def sfu_is_configured(enabled, url, api_key, api_secret):
    return bool(enabled and url and api_key and api_secret)


def private_room_name(call_id, api_secret):
    digest = hmac.new(
        api_secret.encode("utf-8"),
        call_id.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return f"mesh-{digest[:32]}"


def build_livekit_access_token(
    *,
    api_key,
    api_secret,
    room,
    identity,
    display_name="",
    ttl_seconds=300,
    now=None,
):
    issued_at = int(time.time() if now is None else now)
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "iss": api_key,
        "sub": identity,
        "nbf": issued_at - 5,
        "exp": issued_at + int(ttl_seconds),
        "jti": uuid.uuid4().hex,
        "name": display_name or identity,
        "video": {
            "roomJoin": True,
            "room": room,
            "canPublish": True,
            "canSubscribe": True,
            "canPublishData": True,
        },
    }
    encoded_header = _base64url(
        json.dumps(header, separators=(",", ":")).encode("utf-8")
    )
    encoded_payload = _base64url(
        json.dumps(payload, separators=(",", ":")).encode("utf-8")
    )
    signing_input = f"{encoded_header}.{encoded_payload}".encode("ascii")
    signature = hmac.new(
        api_secret.encode("utf-8"),
        signing_input,
        hashlib.sha256,
    ).digest()
    return f"{encoded_header}.{encoded_payload}.{_base64url(signature)}"
