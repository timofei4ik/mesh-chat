from __future__ import annotations

import argparse
import base64
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from decimal import Decimal, InvalidOperation
from ipaddress import ip_address, ip_network
from pathlib import Path
from urllib.parse import urlparse


ROOT_DIR = Path(__file__).resolve().parents[2]
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from server import config


PLACEHOLDER_MARKERS = (
    "YOUR_",
    "PASTE_",
    "GENERATE_",
)


def _is_real_secret(value):
    normalized = str(value or "").strip()
    upper_value = normalized.upper()
    return bool(normalized) and not any(
        marker in upper_value for marker in PLACEHOLDER_MARKERS
    )


def _valid_wireguard_public_key(value):
    try:
        decoded = base64.b64decode(str(value or ""), validate=True)
    except (ValueError, TypeError):
        return False
    return len(decoded) == 32


def _valid_https_url(value):
    normalized = str(value or "").strip()
    if not _is_real_secret(normalized):
        return False
    parsed = urlparse(normalized)
    return parsed.scheme == "https" and bool(parsed.netloc)


def collect_readiness(check_live=False):
    errors = []
    warnings = []

    lava_values = {
        "MESH_LAVA_API_KEY": config.LAVA_API_KEY,
        "MESH_LAVA_WEBHOOK_KEY": config.LAVA_WEBHOOK_KEY,
        "MESH_LAVA_PRODUCT_ID": config.LAVA_PRODUCT_ID,
        "MESH_LAVA_OFFER_ID": config.LAVA_OFFER_ID,
    }
    lava_configured = all(
        _is_real_secret(value) for value in lava_values.values()
    ) and _valid_https_url(config.SUBSCRIPTION_CHECKOUT_URL)
    lava_started = any(
        _is_real_secret(value) for value in lava_values.values()
    )
    if lava_started and not lava_configured:
        for name, value in lava_values.items():
            if not _is_real_secret(value):
                errors.append(
                    f"{name} is missing or still contains a placeholder"
                )
        if not _valid_https_url(config.SUBSCRIPTION_CHECKOUT_URL):
            errors.append(
                "MESH_SUBSCRIPTION_CHECKOUT_URL must be a non-placeholder "
                "HTTPS URL"
            )
    if _is_real_secret(config.LAVA_WEBHOOK_KEY) and not (
        32 <= len(config.LAVA_WEBHOOK_KEY) <= 80
    ):
        errors.append(
            "MESH_LAVA_WEBHOOK_KEY must contain 32 to 80 characters"
        )
    if not _valid_https_url(config.LAVA_API_URL):
        errors.append("MESH_LAVA_API_URL must be an HTTPS URL")

    yookassa_values = {
        "MESH_YOOKASSA_SHOP_ID": config.YOOKASSA_SHOP_ID,
        "MESH_YOOKASSA_SECRET_KEY": config.YOOKASSA_SECRET_KEY,
        "MESH_YOOKASSA_WEBHOOK_SECRET": config.YOOKASSA_WEBHOOK_SECRET,
    }
    yookassa_configured = all(
        _is_real_secret(value) for value in yookassa_values.values()
    )
    yookassa_started = any(
        _is_real_secret(value) for value in yookassa_values.values()
    )
    if yookassa_started and not yookassa_configured:
        for name, value in yookassa_values.items():
            if not _is_real_secret(value):
                errors.append(
                    f"{name} is missing or still contains a placeholder"
                )
    if yookassa_configured and len(config.YOOKASSA_WEBHOOK_SECRET) < 32:
        errors.append(
            "MESH_YOOKASSA_WEBHOOK_SECRET must contain at least 32 characters"
        )

    manual_configured = bool(
        _valid_https_url(config.SBER_PAYMENT_URL)
        and _valid_https_url(config.SUBSCRIPTION_CHECKOUT_URL)
    )
    manual_started = bool(str(config.SBER_PAYMENT_URL or "").strip())
    if manual_started and not manual_configured:
        if not _valid_https_url(config.SBER_PAYMENT_URL):
            errors.append(
                "MESH_SBER_PAYMENT_URL must be a non-placeholder HTTPS URL"
            )
        if not _valid_https_url(config.SUBSCRIPTION_CHECKOUT_URL):
            errors.append(
                "MESH_SUBSCRIPTION_CHECKOUT_URL must be a non-placeholder HTTPS URL"
            )
    boosty_values = {
        "MESH_BOOSTY_TELEGRAM_BOT_TOKEN": config.BOOSTY_TELEGRAM_BOT_TOKEN,
        "MESH_BOOSTY_TELEGRAM_GROUP_ID": config.BOOSTY_TELEGRAM_GROUP_ID,
        "MESH_BOOSTY_ACTIVATION_SECRET": config.BOOSTY_ACTIVATION_SECRET,
    }
    boosty_configured = all(
        _is_real_secret(value) for value in boosty_values.values()
    ) and _valid_https_url(config.BOOSTY_ACTIVATION_URL)
    boosty_started = any(
        _is_real_secret(value) for value in boosty_values.values()
    )
    if boosty_started and not boosty_configured:
        for name, value in boosty_values.items():
            if not _is_real_secret(value):
                errors.append(
                    f"{name} is missing or still contains a placeholder"
                )
        if not _valid_https_url(config.BOOSTY_ACTIVATION_URL):
            errors.append(
                "MESH_BOOSTY_ACTIVATION_URL must be a non-placeholder HTTPS URL"
            )
    if _is_real_secret(config.BOOSTY_ACTIVATION_SECRET) and len(
        config.BOOSTY_ACTIVATION_SECRET
    ) < 32:
        errors.append(
            "MESH_BOOSTY_ACTIVATION_SECRET must contain at least 32 characters"
        )
    if _is_real_secret(config.BOOSTY_TELEGRAM_GROUP_ID):
        try:
            if int(config.BOOSTY_TELEGRAM_GROUP_ID) >= 0:
                raise ValueError
        except ValueError:
            errors.append(
                "MESH_BOOSTY_TELEGRAM_GROUP_ID must be a negative numeric chat id"
            )
    boosty_owner_id = str(config.BOOSTY_TELEGRAM_OWNER_ID or "").strip()
    if boosty_owner_id:
        try:
            if int(boosty_owner_id) <= 0:
                raise ValueError
        except ValueError:
            errors.append(
                "MESH_BOOSTY_TELEGRAM_OWNER_ID must be a positive numeric user id"
            )
    elif boosty_configured:
        warnings.append(
            "MESH_BOOSTY_TELEGRAM_OWNER_ID is missing; /gift is disabled"
        )

    if not any(
        (
            lava_configured,
            manual_configured,
            yookassa_configured,
            boosty_configured,
        )
    ):
        errors.append(
            "configure Boosty Telegram, Lava, manual Sber billing, or YooKassa"
        )

    try:
        if Decimal(config.MESHPRO_MONTHLY_PRICE) <= 0:
            raise InvalidOperation
    except (InvalidOperation, ValueError):
        errors.append("MESH_MESHPRO_MONTHLY_PRICE must be a positive decimal")
    if int(config.MESHPRO_MONTHLY_DAYS) <= 0:
        errors.append("MESH_MESHPRO_MONTHLY_DAYS must be positive")

    if not config.WIREGUARD_ENABLED:
        errors.append("MESH_WG_ENABLED is not enabled")
    if not str(config.WIREGUARD_ENDPOINT or "").strip():
        errors.append("MESH_WG_ENDPOINT is missing")
    if not _valid_wireguard_public_key(config.WIREGUARD_SERVER_PUBLIC_KEY):
        errors.append("MESH_WG_SERVER_PUBLIC_KEY is not a valid WireGuard public key")

    try:
        network = ip_network(config.WIREGUARD_NETWORK, strict=False)
        server_address = ip_address(config.WIREGUARD_SERVER_ADDRESS)
        if server_address not in network:
            errors.append("MESH_WG_SERVER_ADDRESS is outside MESH_WG_NETWORK")
    except ValueError as error:
        errors.append(f"invalid WireGuard network configuration: {error}")

    peer_dir = config.WIREGUARD_PEER_DIR.resolve()
    if str(peer_dir).startswith("/var/www/"):
        errors.append("MESH_WG_PEER_DIR must not be inside the public web root")
    if check_live:
        wireguard_command = shutil.which(config.WIREGUARD_COMMAND)
        if not wireguard_command:
            errors.append(f"WireGuard command not found: {config.WIREGUARD_COMMAND}")
        else:
            result = subprocess.run(
                [wireguard_command, "show", config.WIREGUARD_INTERFACE],
                capture_output=True,
                check=False,
                text=True,
                timeout=5,
            )
            if result.returncode != 0:
                errors.append(
                    f"WireGuard interface {config.WIREGUARD_INTERFACE} is not ready"
                )

        health_url = (
            f"http://{config.BILLING_HOST}:{config.BILLING_PORT}/billing/health"
        )
        try:
            with urllib.request.urlopen(health_url, timeout=5) as response:
                health = json.load(response)
            if not health.get("ok"):
                errors.append("billing health endpoint reports ok=false")
        except (OSError, ValueError, urllib.error.URLError) as error:
            errors.append(f"billing health endpoint is unavailable: {error}")
    elif not peer_dir.exists():
        warnings.append(f"peer directory will need to be created: {peer_dir}")

    return {
        "ok": not errors,
        "product": "meshpro",
        "providers": [
            provider
            for provider, enabled in (
                ("lava", lava_configured),
                ("sber_manual", manual_configured),
                ("yookassa", yookassa_configured),
                ("boosty_telegram", boosty_configured),
            )
            if enabled
        ],
        "live_checks": bool(check_live),
        "errors": errors,
        "warnings": warnings,
    }


def main():
    parser = argparse.ArgumentParser(description="Check MeshPro billing readiness")
    parser.add_argument(
        "--live",
        action="store_true",
        help="also check wg0 and the local billing HTTP endpoint",
    )
    args = parser.parse_args()
    report = collect_readiness(check_live=args.live)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
