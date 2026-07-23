try:
    from server.server_command_bus import account_login, send_json
except ModuleNotFoundError:
    from server_command_bus import account_login, send_json


async def handle_scheduled_message_create(server, packet, context):
    ok, reason, item = server.create_scheduled_message(
        context.node_id,
        packet,
    )
    await send_json(
        context.websocket,
        {
            "type": "scheduled_message_result",
            "action": "create",
            "request_id": packet.get("request_id"),
            "ok": ok,
            "reason": reason,
            "item": item,
        },
    )


async def handle_scheduled_message_cancel(server, packet, context):
    schedule_id = packet.get("schedule_id")
    ok = server.cancel_scheduled_message(context.node_id, schedule_id)
    await send_json(
        context.websocket,
        {
            "type": "scheduled_message_result",
            "action": "cancel",
            "request_id": packet.get("request_id"),
            "ok": ok,
            "reason": "ok" if ok else "not_found",
            "schedule_id": schedule_id,
        },
    )


async def handle_scheduled_messages_request(server, packet, context):
    await send_json(
        context.websocket,
        {
            "type": "scheduled_messages",
            "items": server.list_scheduled_messages(
                account_login(server, context.node_id)
            ),
        },
    )


def register_automation_commands(registry):
    registry.register(
        "scheduled_message_create",
        handle_scheduled_message_create,
    )
    registry.register(
        "scheduled_message_cancel",
        handle_scheduled_message_cancel,
    )
    registry.register(
        "scheduled_messages_request",
        handle_scheduled_messages_request,
    )
