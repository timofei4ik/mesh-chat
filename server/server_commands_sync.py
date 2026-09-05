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


async def handle_reliable_delivery_ack(server, packet, context):
    outbox = getattr(server, "delivery_outbox", None)
    delivery_id = packet.get("delivery_id")
    login = account_login(server, context.node_id)
    if outbox is None or not login or not isinstance(delivery_id, str) or len(delivery_id) != 64:
        return
    latency = outbox.acknowledge(context.node_id, login, delivery_id)
    if latency is not None:
        server.runtime_metrics.increment("delivery_acked_total")
        server.runtime_metrics.observe("delivery_ack", latency)


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


async def handle_reliable_sync_request(server, packet, context):
    login = account_login(server, context.node_id)
    caps = server.client_capabilities.get(context.node_id, {})
    if (not login or context.start_account_sync is None
            or not caps.get("reliable_sync_v2")
            or getattr(server, "sync_delivery_queue", None) is None):
        return
    await context.start_account_sync(server.send_account_sync(
        context.websocket, login, context.node_id,
        caps.get("sticker_library_chunks", False), True,
        caps.get("sync_v2_delta", False), packet.get("cursor", 0),
        caps.get("media_delivery_v2", False), caps.get("sync_v2_delta_batch", False),
    ), replace=False)


async def handle_mutation_status_request(server, packet, context):
    mutation_reconcile = (
        server.client_capabilities.get(context.node_id, {}).get(
            "mutation_reconcile"
        )
        is True
    )
    if not mutation_reconcile:
        return False

    login = account_login(server, context.node_id)
    raw_outbox_ids = packet.get("outbox_ids")
    if not login or not isinstance(raw_outbox_ids, list):
        await send_json(
            context.websocket,
            {
                "type": "mutation_status_result",
                "request_id": packet.get("request_id") or "",
                "processed_outbox_ids": [],
                **version_payload(),
            },
        )
        return

    outbox_ids = []
    seen = set()
    for value in raw_outbox_ids[:500]:
        outbox_id = str(value or "").strip()
        if not outbox_id or outbox_id in seen or len(outbox_id) > 512:
            continue
        seen.add(outbox_id)
        outbox_ids.append(outbox_id)

    processed = [
        outbox_id
        for outbox_id in outbox_ids
        if server.mutation_was_processed(login, outbox_id)
    ]
    await send_json(
        context.websocket,
        {
            "type": "mutation_status_result",
            "request_id": packet.get("request_id") or "",
            "processed_outbox_ids": processed,
            **version_payload(),
        },
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
    if transfer_result.get("ok") is False:
        metrics = getattr(server, "runtime_metrics", None)
        if metrics is not None:
            metrics.increment("file_errors_total")
    await server.send_file_transfer_ack(
        context.websocket,
        packet,
        transfer_result,
    )
    if transfer_result.get("newly_completed") is True:
        await server.deliver_completed_file_transfer(transfer_result)


def register_sync_control_commands(registry):
    registry.register("reliable_sync_request", handle_reliable_sync_request)
    registry.register("reliable_delivery_ack", handle_reliable_delivery_ack)
    registry.register("offline_packet_ack", handle_offline_packet_ack)
    registry.register("sync_v2_ack", handle_sync_v2_ack)
    registry.register(
        "sync_v2_snapshot_request",
        handle_sync_v2_snapshot_request,
    )
    registry.register(
        "mutation_status_request",
        handle_mutation_status_request,
    )
    registry.register("file_transfer_cancel", handle_file_transfer_cancel)
    registry.register("file_chunk", handle_file_chunk_v2)
