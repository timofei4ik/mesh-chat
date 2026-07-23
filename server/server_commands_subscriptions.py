import json
import uuid

try:
    from server.server_billing import BillingError
    from server.server_command_bus import account_login, send_json
except ModuleNotFoundError:
    from server_billing import BillingError
    from server_command_bus import account_login, send_json


async def handle_meshpro_catalog(server, packet, context):
    product = str(packet.get("product") or "meshpro").strip().lower()
    catalog = server.subscription_catalog(product)
    await send_json(
        context.websocket,
        {
            "type": "meshpro_catalog_result",
            "ok": catalog is not None,
            "catalog": catalog,
            "error": None if catalog is not None else "unsupported_product",
        },
    )


async def handle_subscription_status(server, packet, context):
    authenticated_login = (
        server.service_logins.get(context.node_id)
        if context.is_service_connection
        else server.client_logins.get(context.node_id)
    )
    product = str(packet.get("product") or "meshpro").strip().lower()
    await send_json(
        context.websocket,
        {
            "type": "subscription_status_result",
            "ok": bool(authenticated_login),
            "subscription": (
                server.subscription_status(authenticated_login, product)
                if authenticated_login
                else None
            ),
        },
    )


async def handle_subscription_checkout(server, packet, context):
    is_meshprivacy = (
        server.service_clients.get(context.node_id) is context.websocket
        and server.client_services.get(context.node_id) == "meshprivacy"
    )
    authenticated_login = (
        server.service_logins.get(context.node_id)
        if is_meshprivacy
        else None
    )
    result = None
    error = "unauthorized_service"
    if authenticated_login:
        try:
            result = await server.create_subscription_checkout(
                authenticated_login,
                context.node_id,
                packet.get("client_request_id"),
                packet.get("product") or "meshpro",
                packet.get("plan_code") or "monthly",
                buyer_email=packet.get("email"),
            )
            error = None
        except BillingError as billing_error:
            error = str(billing_error)
        except Exception as checkout_error:
            print(
                "Subscription checkout failed:",
                authenticated_login,
                checkout_error,
            )
            error = "checkout_failed"

    await send_json(
        context.websocket,
        {
            "type": "subscription_checkout_result",
            "ok": bool(result),
            "error": error,
            "checkout": result,
        },
    )


async def handle_vpn_config_request(server, packet, context):
    is_meshprivacy = (
        server.service_clients.get(context.node_id) is context.websocket
        and server.client_services.get(context.node_id) == "meshprivacy"
    )
    authenticated_login = (
        server.service_logins.get(context.node_id)
        if is_meshprivacy
        else None
    )
    config = None
    subscription = None
    reason = "unauthorized_service"
    if authenticated_login and is_meshprivacy:
        config, subscription, reason = server.vpn_config_for(
            authenticated_login,
            context.node_id,
        )

    await send_json(
        context.websocket,
        {
            "type": "vpn_config_result",
            "ok": bool(config),
            "reason": reason,
            "config": config,
            "subscription": subscription,
        },
    )


async def handle_service_logout(server, packet, context):
    if context.is_service_connection:
        service_name = server.client_services.get(context.node_id)
        service_login = server.service_logins.get(context.node_id)
        server.revoke_service_session(
            packet.get("service_session_token"),
            service_name,
        )
        if service_name == "meshprivacy" and service_login:
            server.revoke_wireguard_peers(
                service_login,
                "meshpro",
                context.node_id,
            )

    await send_json(
        context.websocket,
        {"type": "service_logout_result", "ok": True},
    )


async def handle_meshpro_preferences_update(server, packet, context):
    preference_login = account_login(server, context.node_id)
    ok, reason = server.save_meshpro_preferences(
        preference_login,
        packet.get("quick_reactions"),
        packet.get("hd_audio") is True,
        packet.get("enhanced_noise_suppression") is True,
    )
    preferences = server.get_meshpro_preferences(preference_login)
    if ok:
        server.invalidate_sync_v2_snapshot(
            preference_login,
            "meshpro_preferences_changed",
            packet.get("operation_id")
            or packet.get("request_id")
            or str(uuid.uuid4()),
        )
    await send_json(
        context.websocket,
        {
            "type": "meshpro_preferences_result",
            "request_id": packet.get("request_id"),
            "ok": ok,
            "reason": reason,
            "preferences": preferences,
        },
    )

    if not ok:
        return
    update_packet = json.dumps(
        {
            "type": "meshpro_preferences_changed",
            "preferences": preferences,
        },
        ensure_ascii=False,
    )
    for account_node in server.get_online_account_nodes(preference_login):
        if account_node == context.node_id:
            continue
        account_socket = server.clients.get(account_node)
        if account_socket:
            await account_socket.send(update_packet)


async def handle_chat_preferences_update(server, packet, context):
    preference_login = account_login(server, context.node_id)
    ok, reason = server.save_chat_preferences(
        preference_login,
        packet.get("chat_key"),
        packet.get("theme_id"),
        packet.get("bubble_style"),
        packet.get("animated_background") is True,
    )
    if ok:
        server.invalidate_sync_v2_snapshot(
            preference_login,
            "chat_preferences_changed",
            packet.get("operation_id")
            or packet.get("request_id")
            or str(uuid.uuid4()),
            {"chat_key": packet.get("chat_key")},
        )
    await send_json(
        context.websocket,
        {
            "type": "chat_preferences_result",
            "ok": ok,
            "reason": reason,
            "chat_key": packet.get("chat_key"),
        },
    )


def register_subscription_commands(registry):
    registry.register("meshpro_catalog_request", handle_meshpro_catalog)
    registry.register(
        "subscription_status_request",
        handle_subscription_status,
    )
    registry.register(
        "subscription_checkout_request",
        handle_subscription_checkout,
    )
    registry.register("vpn_config_request", handle_vpn_config_request)
    registry.register("service_logout", handle_service_logout)
    registry.register(
        "meshpro_preferences_update",
        handle_meshpro_preferences_update,
    )
    registry.register(
        "chat_preferences_update",
        handle_chat_preferences_update,
    )
