import asyncio
import json
from dataclasses import dataclass

try:
    from server.server_command_bus import (
        ConnectionContext,
        StopConnectionHandler,
    )
    from server.server_mutations import (
        execute_history_mutation,
        prepare_mutation,
    )
    from server.server_protocol import (
        SUPPORTED_SERVICES,
        app_version_supported,
        protocol_compatibility,
        version_payload,
    )
except ModuleNotFoundError:
    from server_command_bus import ConnectionContext, StopConnectionHandler
    from server_mutations import execute_history_mutation, prepare_mutation
    from server_protocol import (
        SUPPORTED_SERVICES,
        app_version_supported,
        protocol_compatibility,
        version_payload,
    )


@dataclass(frozen=True)
class HandshakeConfig:
    server_token: str
    require_login: bool
    meshprivacy_min_app_version: str


@dataclass
class HandshakeOutcome:
    node_id: str | None = None
    terminate_handler: bool = False
    sync_operation: object | None = None


async def _send_json(websocket, payload):
    await websocket.send(json.dumps(payload, ensure_ascii=False))


async def handle_server_hello(
    server,
    websocket,
    packet,
    config,
):
    compatible, reason = protocol_compatibility(
        packet.get("protocol_version"),
        packet.get("min_protocol_version"),
    )
    if not compatible:
        await _send_json(
            websocket,
            {
                "type": "server_error",
                "code": "incompatible_protocol",
                "reason": reason,
                "message": (
                    "Incompatible protocol versions. "
                    "Update MeshChat on the client or server."
                ),
                "client_protocol_version": packet.get("protocol_version"),
                "client_min_protocol_version": packet.get(
                    "min_protocol_version"
                ),
                **version_payload(),
            },
        )
        await websocket.close(code=1002, reason="incompatible protocol")
        return HandshakeOutcome(terminate_handler=True)

    if (
        config.server_token
        and packet.get("server_token") != config.server_token
    ):
        print("Client rejected: bad server token")
        await websocket.close(code=1008, reason="bad server token")
        return HandshakeOutcome(terminate_handler=True)

    node_id = packet.get("node_id")
    username = packet.get("username") or node_id
    display_name = packet.get("display_name") or username
    if not node_id:
        return HandshakeOutcome()

    login = packet.get("login")
    password = packet.get("password")
    auth_check = bool(packet.get("auth_check"))
    service = str(packet.get("service") or "").strip().lower()

    if service and service not in SUPPORTED_SERVICES:
        await websocket.close(code=1008, reason="unsupported service")
        return HandshakeOutcome(node_id, terminate_handler=True)

    if (
        service == "meshprivacy"
        and not app_version_supported(
            packet.get("app_version"),
            config.meshprivacy_min_app_version,
        )
    ):
        await _send_json(
            websocket,
            {
                "type": "server_error",
                "code": "meshprivacy_update_required",
                "message": (
                    "This MeshPrivacy version is retired. "
                    f"Install version {config.meshprivacy_min_app_version} "
                    "or newer."
                ),
                "minimum_app_version": config.meshprivacy_min_app_version,
            },
        )
        await websocket.close(
            code=1008,
            reason="MeshPrivacy update required",
        )
        return HandshakeOutcome(node_id, terminate_handler=True)

    service_session_token = str(
        packet.get("service_session_token") or ""
    ).strip()
    issued_service_token = None
    if service_session_token:
        login = server.authenticate_service_session(
            service_session_token,
            service,
            node_id,
        )
        if not login:
            await _send_json(
                websocket,
                {
                    "type": "server_error",
                    "code": "service_session_invalid",
                    "message": "Service session expired or was revoked",
                },
            )
            await websocket.close(
                code=1008,
                reason="service session expired",
            )
            return HandshakeOutcome(node_id, terminate_handler=True)
    elif config.require_login or login or password or service:
        email_ok, email_error, verified_email = (
            await server.authorize_email_2fa(
                packet,
                login,
                password,
                node_id,
            )
        )
        if not email_ok:
            await server.send_server_error(
                websocket,
                email_error.pop("code"),
                email_error.pop("message"),
                **email_error,
            )
            await websocket.close(
                code=1008,
                reason="email verification required",
            )
            return HandshakeOutcome(node_id, terminate_handler=True)

        account_existed = server.account_exists(login)
        ok, reason = server.authenticate_account(
            login,
            password,
            node_id,
            display_name,
            auth_check,
            packet.get("public_username"),
            packet.get("about"),
            packet.get("avatar_data"),
            packet.get("encryption_public_key"),
            bool(packet.get("register_if_missing", True)),
            bool(packet.get("reactivate_device", False)),
            verified_email,
            bool(verified_email) and not account_existed,
        )
        if not ok:
            await server.send_server_error(
                websocket,
                "authentication_failed",
                reason,
            )
            print(f"Client rejected: {reason}")
            await websocket.close(code=1008, reason=reason)
            return HandshakeOutcome(node_id, terminate_handler=True)

        if verified_email:
            server.trust_email_device(login, node_id)
        if service and not auth_check:
            issued_service_token = server.create_service_session(
                login,
                service,
                node_id,
            )

    if auth_check:
        await _send_json(
            websocket,
            {
                "type": "server_welcome",
                "web_push_vapid_public_key": server.web_push_public_key(),
                "encryption_recovery": (
                    server.get_account_encryption_recovery(login)
                    if login
                    else ""
                ),
                "email_binding_required": (
                    server.email_binding_required(login) if login else False
                ),
                "email": server.mask_email(server.account_email(login)),
                **version_payload(),
            },
        )
        return HandshakeOutcome(node_id, terminate_handler=True)

    if service:
        normalized_login = login.strip().lower()
        server.service_clients[node_id] = websocket
        server.client_services[node_id] = service
        server.service_logins[node_id] = normalized_login
        welcome = {
            "type": "server_welcome",
            "service": service,
            "login": normalized_login,
            "subscription": server.subscription_status(
                normalized_login,
                service,
            ),
            **version_payload(),
        }
        if issued_service_token:
            welcome["service_session_token"] = issued_service_token
        await _send_json(websocket, welcome)
        print(f"Service online: {service}/{normalized_login} ({node_id})")
        return HandshakeOutcome(node_id)

    server.clients[node_id] = websocket
    server.client_names[node_id] = username

    delta_enabled = server.sync_v2_delta_enabled_for(login)
    server.client_capabilities[node_id] = {
        "sync_v2": bool(packet.get("supports_sync_v2", False)),
        "sync_v2_delta": bool(
            packet.get("supports_sync_v2_delta", False)
        ) and delta_enabled,
        "sticker_library_chunks": bool(
            packet.get("supports_sticker_library_chunks", False)
        ),
        "offline_packet_ack": bool(
            packet.get("supports_offline_packet_ack", False)
        ),
        "mutation_ack": bool(
            packet.get("supports_mutation_ack", False)
        ),
        "file_transfer_v2": bool(
            packet.get("supports_file_transfer_v2", False)
        ),
        "account_live_fanout": bool(
            packet.get("supports_account_live_fanout", False)
        ),
    }

    normalized_login = ""
    if login:
        normalized_login = login.strip().lower()
        server.client_logins[node_id] = normalized_login
        server.save_account_device(
            normalized_login,
            node_id,
            display_name,
            packet.get("app_version"),
            True,
            packet.get("device_name"),
        )

    welcome = {
        "type": "server_welcome",
        "web_push_vapid_public_key": server.web_push_public_key(),
        "capabilities": {
            "sync_v2": True,
            "sync_v2_delta": delta_enabled,
            "offline_packet_ack": True,
            "mutation_ack": True,
            "file_transfer_v2": True,
            "account_live_fanout": True,
            "email_2fa": True,
        },
        **version_payload(),
    }
    if login:
        welcome["subscription"] = server.subscription_status(
            normalized_login,
            "meshpro",
        )
        welcome["account_group_ids"] = server.account_group_ids(
            normalized_login,
            node_id,
        )
        welcome["encryption_recovery"] = (
            server.get_account_encryption_recovery(normalized_login)
        )
        welcome["email_binding_required"] = (
            server.email_binding_required(normalized_login)
        )
        welcome["email"] = server.mask_email(
            server.account_email(normalized_login)
        )

    await _send_json(websocket, welcome)
    print(f"Client online: {username} ({node_id})")

    if not login:
        await server.send_user_list()
        await server.flush_offline_packets(
            node_id,
            websocket,
            bool(packet.get("supports_offline_packet_ack", False)),
        )
        return HandshakeOutcome(node_id)

    sync_sticker_chunks = bool(
        packet.get("supports_sticker_library_chunks", False)
    )
    sync_v2 = bool(packet.get("supports_sync_v2", False))
    sync_v2_delta = bool(
        packet.get("supports_sync_v2_delta", False)
    ) and delta_enabled
    sync_cursor = packet.get("sync_cursor", 0)
    sync_offline_ack = bool(
        packet.get("supports_offline_packet_ack", False)
    )

    async def send_initial_account_state():
        await server.send_account_sync(
            websocket,
            normalized_login,
            node_id,
            sync_sticker_chunks,
            sync_v2,
            sync_v2_delta,
            sync_cursor,
        )
        await server.send_user_list()
        await server.flush_offline_packets(
            node_id,
            websocket,
            sync_offline_ack,
        )

    return HandshakeOutcome(
        node_id,
        sync_operation=send_initial_account_state(),
    )


async def cleanup_connection(server, websocket, node_id):
    if (
        node_id
        and server.service_clients.get(node_id) is websocket
    ):
        service = server.client_services.pop(node_id, None)
        login = server.service_logins.pop(node_id, None)
        server.service_clients.pop(node_id, None)
        print(f"Service offline: {service}/{login} ({node_id})")

    if not (
        node_id
        and server.clients.get(node_id) is websocket
    ):
        return

    server.clients.pop(node_id, None)
    server.client_names.pop(node_id, None)
    server.client_capabilities.pop(node_id, None)
    login = server.client_logins.pop(node_id, None)
    if login:
        server.set_account_device_online(login, node_id, False)
    print(f"Client offline: {node_id}")
    await server.send_user_list()


async def handle_connection(server, websocket, config):
    node_id = None
    account_sync_task = None

    async def start_account_sync(sync_operation):
        nonlocal account_sync_task
        if account_sync_task is not None and not account_sync_task.done():
            account_sync_task.cancel()
            await asyncio.gather(account_sync_task, return_exceptions=True)

        account_sync_task = asyncio.create_task(
            sync_operation,
            name=f"account-sync:{node_id or 'pending'}",
        )

        def report_sync_failure(task):
            if task.cancelled():
                return
            error = task.exception()
            if error is not None:
                print(f"Account sync failed for {node_id}: {error!r}")

        account_sync_task.add_done_callback(report_sync_failure)
        await asyncio.sleep(0)

    try:
        async for raw_message in websocket:
            try:
                packet = json.loads(raw_message)
            except json.JSONDecodeError:
                continue

            if packet.get("type") == "server_hello":
                outcome = await handle_server_hello(
                    server,
                    websocket,
                    packet,
                    config,
                )
                node_id = outcome.node_id
                if outcome.sync_operation is not None:
                    await start_account_sync(outcome.sync_operation)
                if outcome.terminate_handler:
                    return
                continue
            if not node_id:
                continue

            packet_source = packet.get("source_node")
            if packet_source and packet_source != node_id:
                print(
                    "Rejected packet with forged source:",
                    node_id,
                    packet_source,
                )
                continue

            is_service_connection = (
                server.service_clients.get(node_id) is websocket
            )
            if (
                not is_service_connection
                and server.clients.get(node_id) is not websocket
            ):
                await websocket.close(
                    code=1008,
                    reason="connection was replaced",
                )
                return

            if (
                is_service_connection
                and packet.get("type") not in {
                    "meshpro_catalog_request",
                    "subscription_status_request",
                    "subscription_checkout_request",
                    "vpn_config_request",
                    "service_logout",
                }
            ):
                await _send_json(
                    websocket,
                    {
                        "type": "server_error",
                        "code": "unsupported_service_packet",
                        "message": (
                            "Packet is not available for this service"
                        ),
                    },
                )
                continue

            command_context = ConnectionContext(
                websocket=websocket,
                node_id=node_id,
                is_service_connection=is_service_connection,
                start_account_sync=start_account_sync,
            )
            try:
                control_handled = (
                    await server.control_command_registry.dispatch(
                        server,
                        packet,
                        command_context,
                    )
                )
            except StopConnectionHandler:
                return
            if control_handled:
                continue

            mutation_preparation = await prepare_mutation(
                server,
                websocket,
                node_id,
                packet,
            )
            if mutation_preparation.duplicate:
                continue

            if await server.command_registry.dispatch(
                server,
                packet,
                command_context,
            ):
                continue

            await execute_history_mutation(
                server,
                websocket,
                node_id,
                packet,
                mutation_preparation.context,
            )
    finally:
        if account_sync_task is not None:
            if not account_sync_task.done():
                account_sync_task.cancel()
            await asyncio.gather(
                account_sync_task,
                return_exceptions=True,
            )
        await cleanup_connection(server, websocket, node_id)
