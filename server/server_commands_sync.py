try:
    from server.server_command_bus import account_login, send_json
    from server.server_protocol import version_payload
except ModuleNotFoundError:
    from server_command_bus import account_login, send_json
    from server_protocol import version_payload


async def handle_offline_packet_ack(server, packet, context):
    server.acknowledge_offline_packet(
        context.node_id,
        packet.get("queue_id"),
    )


async def handle_sync_v2_ack(server, packet, context):
    server.acknowledge_sync_v2_cursor(
        account_login(server, context.node_id),
        context.node_id,
        packet.get("cursor"),
    )


async def handle_sync_v2_snapshot_request(server, packet, context):
    login = account_login(server, context.node_id)
    if not login or context.start_account_sync is None:
        return
    capabilities = server.client_capabilities.get(context.node_id, {})
    await context.start_account_sync(
        server.send_account_sync(
            context.websocket,
            login,
            context.node_id,
            capabilities.get("sticker_library_chunks") is True,
            capabilities.get("sync_v2") is True,
            False,
            0,
        )
    )


async def handle_file_transfer_cancel(server, packet, context):
    file_transfer_v2 = (
        server.client_capabilities.get(context.node_id, {}).get(
            "file_transfer_v2"
        ) is True
    )
    if not file_transfer_v2:
        return False

    login = (
        account_login(server, context.node_id)
        or f"@node:{context.node_id}"
    )
    cancelled = server.cancel_file_transfer(
        login,
        packet.get("transfer_id"),
    )
    await send_json(
        context.websocket,
        {
            "type": "file_chunk_ack",
            "ok": True,
            "cancelled": cancelled,
            "transfer_id": packet.get("transfer_id"),
            "file_id": packet.get("file_id"),
            "operation_id": packet.get("operation_id"),
            "received_ranges": [],
            "complete": False,
            **version_payload(),
        },
    )


async def handle_file_chunk_v2(server, packet, context):
    file_transfer_v2 = (
        server.client_capabilities.get(context.node_id, {}).get(
            "file_transfer_v2"
        ) is True
    )
    if (
        not file_transfer_v2
        or packet.get("file_transfer_v2") is not True
    ):
        return False

    packet["source_node"] = context.node_id
    login = (
        account_login(server, context.node_id)
        or f"@node:{context.node_id}"
    )
    transfer_result = server.save_file_transfer_chunk(packet, login)
    await server.send_file_transfer_ack(
        context.websocket,
        packet,
        transfer_result,
    )
    if transfer_result.get("newly_completed") is True:
        await server.deliver_completed_file_transfer(transfer_result)


def register_sync_control_commands(registry):
    registry.register("offline_packet_ack", handle_offline_packet_ack)
    registry.register("sync_v2_ack", handle_sync_v2_ack)
    registry.register(
        "sync_v2_snapshot_request",
        handle_sync_v2_snapshot_request,
    )
    registry.register("file_transfer_cancel", handle_file_transfer_cancel)
    registry.register("file_chunk", handle_file_chunk_v2)
