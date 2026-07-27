"""Create or remove an isolated account used by the WebSocket load generator."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from server.server import MeshRelayServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--login", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--output", default="")
    parser.add_argument("--delete", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.count <= 5000:
        raise ValueError("--count must be between 1 and 5000")

    relay = MeshRelayServer()
    accounts = []
    failures = []
    removed = 0
    for index in range(args.count):
        login = (
            args.login
            if args.count == 1
            else f"{args.login}_{index:05d}"
        )
        if args.delete:
            removed += int(bool(relay.delete_account(login, args.password)))
            continue
        ok, reason = relay.authenticate_account(
            login,
            args.password,
            f"load-bootstrap-{login}",
            "MeshChat load test",
        )
        if ok:
            accounts.append(
                {"login": login, "password": args.password}
            )
        else:
            failures.append(
                {"login": login, "reason": str(reason or "")}
            )

    if args.output and accounts:
        output = Path(args.output)
        output.write_text(
            json.dumps(accounts, ensure_ascii=False),
            encoding="utf-8",
        )
        try:
            os.chmod(output, 0o600)
        except OSError:
            pass
    result = {
        "login_prefix": args.login,
        "requested": args.count,
        "created_or_verified": len(accounts),
        "removed": removed,
        "failures": failures[:20],
        "output": args.output if accounts else "",
    }
    print(json.dumps(result, sort_keys=True))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
