import ipaddress
import os
import subprocess
import uuid
from pathlib import Path

try:
    from server.config import (
        WIREGUARD_ALLOWED_IPS,
        WIREGUARD_COMMAND,
        WIREGUARD_DNS,
        WIREGUARD_ENABLED,
        WIREGUARD_ENDPOINT,
        WIREGUARD_INTERFACE,
        WIREGUARD_KEEPALIVE,
        WIREGUARD_NETWORK,
        WIREGUARD_PEER_DIR,
        WIREGUARD_SERVER_ADDRESS,
        WIREGUARD_SERVER_PUBLIC_KEY,
    )
    from server.server_subscription import (
        MESHPRO_PRODUCT,
        MESHPRO_PRODUCT_ALIASES,
    )
except ModuleNotFoundError:
    from config import (
        WIREGUARD_ALLOWED_IPS,
        WIREGUARD_COMMAND,
        WIREGUARD_DNS,
        WIREGUARD_ENABLED,
        WIREGUARD_ENDPOINT,
        WIREGUARD_INTERFACE,
        WIREGUARD_KEEPALIVE,
        WIREGUARD_NETWORK,
        WIREGUARD_PEER_DIR,
        WIREGUARD_SERVER_ADDRESS,
        WIREGUARD_SERVER_PUBLIC_KEY,
    )
    from server_subscription import MESHPRO_PRODUCT, MESHPRO_PRODUCT_ALIASES


class WireGuardProvisioningError(RuntimeError):
    pass


class ServerWireGuardMixin:
    def wireguard_config_for(self, login, device_id):
        self._require_wireguard_ready()
        normalized_login = (login or "").strip().lower()
        normalized_device = (device_id or "").strip()
        if not normalized_login or not normalized_device:
            raise WireGuardProvisioningError("login and device_id are required")

        row = self.db.execute(
            """
            SELECT peer_id, address, public_key, config_path, status
            FROM vpn_peers
            WHERE login=?
              AND product IN ('meshpro', 'meshprivacy')
              AND device_id=?
            ORDER BY CASE product WHEN 'meshpro' THEN 0 ELSE 1 END
            LIMIT 1
            """,
            (normalized_login, normalized_device),
        ).fetchone()
        if row and row[4] != "revoked":
            config_path = Path(row[3])
            if config_path.is_file():
                self._apply_wireguard_peer(row[2], row[1])
                self.db.execute(
                    """
                    UPDATE vpn_peers
                    SET last_applied_at=CURRENT_TIMESTAMP,
                        updated_at=CURRENT_TIMESTAMP
                    WHERE peer_id=?
                    """,
                    (row[0],),
                )
                self.db.commit()
                return config_path.read_text(encoding="utf-8").strip()
            self._remove_wireguard_peer(row[2])

        peer_id = row[0] if row else str(uuid.uuid4())
        address = self._allocate_wireguard_address(peer_id)
        private_key, public_key = self._generate_wireguard_keys()
        config_path = self._wireguard_peer_path(peer_id)
        config = self._render_wireguard_config(private_key, address)
        self._write_private_config(config_path, config)

        self.db.execute(
            """
            INSERT INTO vpn_peers(
                peer_id,
                login,
                product,
                device_id,
                address,
                public_key,
                config_path,
                status,
                updated_at
            )
            VALUES(?, ?, ?, ?, ?, ?, ?, 'provisioning', CURRENT_TIMESTAMP)
            ON CONFLICT(login, product, device_id) DO UPDATE SET
                address=excluded.address,
                public_key=excluded.public_key,
                config_path=excluded.config_path,
                status='provisioning',
                revoked_at=NULL,
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                peer_id,
                normalized_login,
                MESHPRO_PRODUCT,
                normalized_device,
                address,
                public_key,
                str(config_path),
            ),
        )
        self.db.commit()

        try:
            self._apply_wireguard_peer(public_key, address)
        except Exception:
            self.db.execute(
                """
                UPDATE vpn_peers
                SET status='provision_failed', updated_at=CURRENT_TIMESTAMP
                WHERE peer_id=?
                """,
                (peer_id,),
            )
            self.db.commit()
            raise

        self.db.execute(
            """
            UPDATE vpn_peers
            SET status='active',
                last_applied_at=CURRENT_TIMESTAMP,
                updated_at=CURRENT_TIMESTAMP
            WHERE peer_id=?
            """,
            (peer_id,),
        )
        self.db.commit()
        return config

    def revoke_wireguard_peers(
        self,
        login,
        product=MESHPRO_PRODUCT,
        device_id=None,
    ):
        normalized_login = (login or "").strip().lower()
        normalized_product = self.normalize_subscription_product(product)
        products = (
            tuple(MESHPRO_PRODUCT_ALIASES)
            if normalized_product == MESHPRO_PRODUCT
            else (normalized_product,)
        )
        product_placeholders = ",".join("?" for _ in products)
        parameters = [normalized_login, *products]
        device_clause = ""
        if device_id:
            device_clause = " AND device_id=?"
            parameters.append((device_id or "").strip())
        rows = self.db.execute(
            f"""
            SELECT peer_id, public_key, config_path
            FROM vpn_peers
            WHERE login=? AND product IN ({product_placeholders})
              AND status NOT IN ('revoked')
              {device_clause}
            """,
            tuple(parameters),
        ).fetchall()

        failures = []
        for peer_id, public_key, config_path in rows:
            try:
                self._remove_wireguard_peer(public_key)
            except Exception as error:
                failures.append({"peer_id": peer_id, "error": str(error)})
                self.db.execute(
                    """
                    UPDATE vpn_peers
                    SET status='revoke_failed', updated_at=CURRENT_TIMESTAMP
                    WHERE peer_id=?
                    """,
                    (peer_id,),
                )
                continue
            try:
                Path(config_path).unlink(missing_ok=True)
            except OSError:
                pass
            self.db.execute(
                """
                UPDATE vpn_peers
                SET status='revoked',
                    config_path='',
                    revoked_at=CURRENT_TIMESTAMP,
                    updated_at=CURRENT_TIMESTAMP
                WHERE peer_id=?
                """,
                (peer_id,),
            )
        self.db.commit()
        if failures:
            print(f"WireGuard peer revoke failures: {failures}")
        return failures

    def reconcile_wireguard_peers(self):
        if not WIREGUARD_ENABLED:
            return {"applied": 0, "revoked": 0, "failed": 0}
        stats = {"applied": 0, "revoked": 0, "failed": 0}
        rows = self.db.execute(
            """
            SELECT peer_id, login, product, public_key, address, config_path
            FROM vpn_peers
            WHERE status IN (
                'active', 'provisioning', 'provision_failed', 'revoke_failed'
            )
            """
        ).fetchall()
        for peer_id, login, product, public_key, address, config_path in rows:
            if not self.has_active_subscription(login, product):
                failures = self.revoke_wireguard_peers(login, product)
                stats["failed" if failures else "revoked"] += 1
                continue
            if not config_path or not Path(config_path).is_file():
                stats["failed"] += 1
                continue
            try:
                self._apply_wireguard_peer(public_key, address)
            except Exception as error:
                print(f"WireGuard reconcile failed for {peer_id}: {error}")
                stats["failed"] += 1
                continue
            self.db.execute(
                """
                UPDATE vpn_peers
                SET status='active',
                    last_applied_at=CURRENT_TIMESTAMP,
                    updated_at=CURRENT_TIMESTAMP
                WHERE peer_id=?
                """,
                (peer_id,),
            )
            stats["applied"] += 1
        self.db.commit()
        return stats

    def _require_wireguard_ready(self):
        if not WIREGUARD_ENABLED:
            raise WireGuardProvisioningError("dynamic WireGuard is disabled")
        if not WIREGUARD_ENDPOINT:
            raise WireGuardProvisioningError("MESH_WG_ENDPOINT is missing")
        ipaddress.ip_network(WIREGUARD_NETWORK, strict=False)
        self._wireguard_server_public_key()

    def _allocate_wireguard_address(self, current_peer_id):
        network = ipaddress.ip_network(WIREGUARD_NETWORK, strict=False)
        if network.version != 4:
            raise WireGuardProvisioningError("only an IPv4 peer pool is supported")
        server_address = ipaddress.ip_address(WIREGUARD_SERVER_ADDRESS)
        used = {
            row[0]
            for row in self.db.execute(
                """
                SELECT address
                FROM vpn_peers
                WHERE product IN ('meshpro', 'meshprivacy')
                  AND status NOT IN ('revoked')
                  AND peer_id != ?
                """,
                (current_peer_id,),
            ).fetchall()
        }
        for address in network.hosts():
            if address == server_address:
                continue
            value = str(address)
            if value not in used:
                return value
        raise WireGuardProvisioningError("the WireGuard address pool is full")

    def _wireguard_peer_path(self, peer_id):
        peer_dir = Path(WIREGUARD_PEER_DIR)
        peer_dir.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(peer_dir, 0o700)
        except OSError:
            pass
        return peer_dir / f"{peer_id}.conf"

    def _generate_wireguard_keys(self):
        private_key = self._run_wireguard(["genkey"]).strip()
        public_key = self._run_wireguard(
            ["pubkey"],
            input_text=f"{private_key}\n",
        ).strip()
        if not private_key or not public_key:
            raise WireGuardProvisioningError("wg returned an empty key")
        return private_key, public_key

    def _wireguard_server_public_key(self):
        if WIREGUARD_SERVER_PUBLIC_KEY:
            return WIREGUARD_SERVER_PUBLIC_KEY
        public_key = self._run_wireguard(
            ["show", WIREGUARD_INTERFACE, "public-key"]
        ).strip()
        if not public_key:
            raise WireGuardProvisioningError("server public key is unavailable")
        return public_key

    def _render_wireguard_config(self, private_key, address):
        lines = [
            "[Interface]",
            f"PrivateKey = {private_key}",
            f"Address = {address}/32",
        ]
        if WIREGUARD_DNS:
            lines.append(f"DNS = {WIREGUARD_DNS}")
        lines.extend(
            [
                "",
                "[Peer]",
                f"PublicKey = {self._wireguard_server_public_key()}",
                f"Endpoint = {WIREGUARD_ENDPOINT}",
                f"AllowedIPs = {WIREGUARD_ALLOWED_IPS}",
                f"PersistentKeepalive = {max(0, int(WIREGUARD_KEEPALIVE))}",
                "",
            ]
        )
        return "\n".join(lines)

    def _write_private_config(self, path, config):
        temporary = path.with_suffix(".tmp")
        temporary.write_text(config, encoding="utf-8", newline="\n")
        try:
            os.chmod(temporary, 0o600)
        except OSError:
            pass
        temporary.replace(path)

    def _apply_wireguard_peer(self, public_key, address):
        self._run_wireguard(
            [
                "set",
                WIREGUARD_INTERFACE,
                "peer",
                public_key,
                "allowed-ips",
                f"{address}/32",
            ]
        )

    def _remove_wireguard_peer(self, public_key):
        if not public_key:
            return
        self._run_wireguard(
            ["set", WIREGUARD_INTERFACE, "peer", public_key, "remove"]
        )

    def _run_wireguard(self, arguments, input_text=None):
        try:
            result = subprocess.run(
                [WIREGUARD_COMMAND, *arguments],
                input=input_text,
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise WireGuardProvisioningError(str(error)) from error
        if result.returncode != 0:
            message = (result.stderr or result.stdout or "wg failed").strip()
            raise WireGuardProvisioningError(message)
        return result.stdout
