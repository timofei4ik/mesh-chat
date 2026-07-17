import argparse
import json

try:
    from server.server import MeshRelayServer
except ModuleNotFoundError:
    from server import MeshRelayServer


def build_parser():
    parser = argparse.ArgumentParser(
        description="Manage Mesh ecosystem subscriptions"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    status = subparsers.add_parser("status", help="Show entitlement status")
    status.add_argument("--login", required=True)
    status.add_argument("--product", default="meshpro")

    grant = subparsers.add_parser("grant", help="Grant or extend access")
    grant.add_argument("--login", required=True)
    grant.add_argument("--product", default="meshpro")
    grant.add_argument("--plan", default="monthly")
    grant.add_argument("--days", type=int, default=30)
    grant.add_argument("--provider", default="manual")

    revoke = subparsers.add_parser("revoke", help="Revoke access")
    revoke.add_argument("--login", required=True)
    revoke.add_argument("--product", default="meshpro")

    pending = subparsers.add_parser(
        "pending",
        help="List manual Sber payment orders",
    )
    pending.add_argument(
        "--status",
        default="awaiting",
        choices=("awaiting", "pending", "reported", "approved", "rejected", "all"),
    )
    pending.add_argument("--limit", type=int, default=50)

    approve = subparsers.add_parser(
        "approve",
        help="Approve a verified manual Sber payment",
    )
    approve.add_argument("--order", required=True)

    reject = subparsers.add_parser(
        "reject",
        help="Reject a manual Sber payment order",
    )
    reject.add_argument("--order", required=True)

    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    relay = MeshRelayServer()
    try:
        if args.command == "status":
            result = relay.subscription_status(args.login, args.product)
        elif args.command == "grant":
            result = relay.grant_subscription(
                args.login,
                product=args.product,
                plan_code=args.plan,
                days=args.days,
                provider=args.provider,
            )
        elif args.command == "revoke":
            result = relay.revoke_subscription(args.login, args.product)
        elif args.command == "pending":
            result = relay.list_manual_subscription_orders(
                status=args.status,
                limit=args.limit,
            )
        elif args.command == "approve":
            result = relay.approve_manual_subscription_order(args.order)
            result["receipt_reminder"] = (
                "Create and send the customer receipt in My Tax."
            )
        else:
            result = relay.reject_manual_subscription_order(args.order)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    finally:
        relay.db.close()


if __name__ == "__main__":
    main()
