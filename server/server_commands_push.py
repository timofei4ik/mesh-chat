try:
    from server.server_command_bus import account_login, send_json
except ModuleNotFoundError:
    from server_command_bus import account_login, send_json


async def handle_web_push_subscribe(server, packet, context):
    server.save_web_push_subscription(
        account_login(server, context.node_id),
        context.node_id,
        packet.get("subscription"),
        packet.get("user_agent") or "",
    )
    await send_json(
        context.websocket,
        {"type": "push_subscribe_result", "ok": True},
    )


async def handle_fcm_subscribe(server, packet, context):
    server.save_android_push_token(
        account_login(server, context.node_id),
        context.node_id,
        packet.get("token"),
    )
    await send_json(
        context.websocket,
        {"type": "fcm_subscribe_result", "ok": True},
    )


async def handle_web_push_unsubscribe(server, packet, context):
    server.delete_web_push_subscription(
        endpoint=packet.get("endpoint"),
        node_id=context.node_id if not packet.get("endpoint") else None,
    )
    await send_json(
        context.websocket,
        {"type": "push_unsubscribe_result", "ok": True},
    )


async def handle_fcm_unsubscribe(server, packet, context):
    server.delete_android_push_token(
        token=packet.get("token"),
        node_id=context.node_id if not packet.get("token") else None,
    )
    await send_json(
        context.websocket,
        {"type": "fcm_unsubscribe_result", "ok": True},
    )


def register_push_commands(registry):
    registry.register("push_subscribe", handle_web_push_subscribe)
    registry.register("fcm_subscribe", handle_fcm_subscribe)
    registry.register("push_unsubscribe", handle_web_push_unsubscribe)
    registry.register("fcm_unsubscribe", handle_fcm_unsubscribe)
