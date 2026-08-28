try:
    from server.server_command_bus import send_json
except ModuleNotFoundError:
    from server_command_bus import send_json


async def _send_result(context, request_id, ok, reason, poll):
    await send_json(
        context.websocket,
        {
            "type": "poll_result",
            "request_id": request_id,
            "ok": ok,
            "reason": reason,
            "poll": poll,
        },
    )


async def handle_poll_create(server, packet, context):
    ok, reason, poll = server.create_group_poll(context.node_id, packet)
    await _send_result(context, packet.get("request_id"), ok, reason, poll)
    if ok:
        await server.broadcast_poll(poll)


async def handle_poll_vote(server, packet, context):
    ok, reason, poll = server.vote_group_poll(
        context.node_id,
        str(packet.get("poll_id") or ""),
        packet.get("selected_options"),
    )
    await _send_result(context, packet.get("request_id"), ok, reason, poll)
    if ok:
        await server.broadcast_poll(poll)


async def handle_poll_close(server, packet, context):
    ok, reason, poll = server.close_group_poll(
        context.node_id,
        str(packet.get("poll_id") or ""),
    )
    await _send_result(context, packet.get("request_id"), ok, reason, poll)
    if ok:
        await server.broadcast_poll(poll)


def register_poll_commands(registry):
    registry.register("poll_create", handle_poll_create)
    registry.register("poll_vote", handle_poll_vote)
    registry.register("poll_close", handle_poll_close)
