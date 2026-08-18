"""Exercise the public account-deletion path with an ephemeral account."""

from __future__ import annotations

import json
import secrets
import time
import urllib.request
import uuid

from server.server import MeshRelayServer


def main() -> int:
    suffix = uuid.uuid4().hex[:12]
    login = f"store_delete_probe_{suffix}"
    password = secrets.token_urlsafe(24)
    relay = MeshRelayServer()
    created = False
    try:
        ok, reason = relay.authenticate_account(
            login,
            password,
            f"store-probe-{suffix}",
            "Store deletion probe",
            public_username=login,
            allow_registration=True,
        )
        if not ok or reason != "registered":
            raise RuntimeError(f"probe account registration failed: {reason}")
        created = True

        request = urllib.request.Request(
            "http://127.0.0.1:8766/meshpro/legal/api/account-deletion",
            data=json.dumps(
                {
                    "login": login,
                    "password": password,
                    "confirmation": "DELETE",
                }
            ).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = json.loads(response.read().decode("utf-8"))
            if response.status != 200 or payload.get("ok") is not True:
                raise RuntimeError(f"deletion endpoint failed: {payload}")

        deleted = False
        for _ in range(20):
            with relay.unit_of_work_factory() as unit_of_work:
                credentials = unit_of_work.identity.credentials(login)
            if credentials is None:
                created = False
                deleted = True
                break
            time.sleep(0.1)
        if not deleted:
            raise RuntimeError("deleted account credentials still exist")
        print("store account-deletion probe: ok")

        support_request = urllib.request.Request(
            "http://127.0.0.1:8766/meshpro/legal/api/support",
            data=json.dumps(
                {
                    "email": f"store-probe-{suffix}@example.invalid",
                    "details": "Automated store-readiness moderation probe.",
                }
            ).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(support_request, timeout=15) as response:
            support_payload = json.loads(response.read().decode("utf-8"))
            report_id = str(support_payload.get("request_id") or "")
            if response.status != 200 or not report_id:
                raise RuntimeError(
                    f"support endpoint failed: {support_payload}"
                )
        with relay.unit_of_work_factory(write=True) as unit_of_work:
            report = unit_of_work.moderation.report_by_id(report_id)
            if report is None or report.get("subject_type") != "support":
                raise RuntimeError("support report did not reach moderation")
            changed = unit_of_work.moderation.record_decision(
                report_id,
                str(uuid.uuid4()),
                "store-readiness-probe",
                "keep",
                "Automated probe completed successfully.",
            )
            if not changed:
                raise RuntimeError("support report could not be resolved")
        print("store support/moderation probe: ok")
        return 0
    finally:
        if created:
            relay.account_deletion_orchestrator.delete(login)
        close = getattr(relay.db, "close", None)
        if callable(close):
            close()


if __name__ == "__main__":
    raise SystemExit(main())
