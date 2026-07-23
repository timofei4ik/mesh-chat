import asyncio

try:
    from server.server_command_bus import (
        StopConnectionHandler,
        account_login,
        send_json,
    )
except ModuleNotFoundError:
    from server_command_bus import (
        StopConnectionHandler,
        account_login,
        send_json,
    )


async def handle_username_lookup(server, packet, context):
    profile = server.find_account_by_public_username(packet.get("username"))
    await send_json(
        context.websocket,
        {
            "type": "username_lookup_result",
            "ok": bool(profile),
            "username": packet.get("username"),
            "profile": profile,
        },
    )


async def handle_profile_update(server, packet, context):
    ok, reason = server.save_account_profile(
        packet.get("login"),
        packet.get("source_node"),
        packet.get("display_name"),
        packet.get("public_username"),
        packet.get("about"),
        packet.get("avatar_data"),
        packet.get("encryption_public_key"),
        packet.get("profile_background"),
        packet.get("profile_effect"),
        packet.get("profile_blink_shape"),
        packet.get("avatar_decoration"),
        packet.get("profile_glow"),
        packet.get("profile_accent"),
        packet.get("emoji_status"),
    )
    await send_json(
        context.websocket,
        {
            "type": "profile_update_result",
            "ok": ok,
            "reason": reason,
            "public_username": packet.get("public_username"),
        },
    )
    if ok:
        await server.send_user_list()


async def handle_active_devices_request(server, packet, context):
    await send_json(
        context.websocket,
        {
            "type": "active_devices",
            "devices": server.get_account_devices(
                account_login(server, context.node_id)
            ),
        },
    )


async def handle_account_password_change(server, packet, context):
    password_login = account_login(server, context.node_id)
    ok, reason = server.change_account_password(
        password_login,
        packet.get("current_password"),
        packet.get("new_password"),
        packet.get("encryption_recovery"),
    )
    await send_json(
        context.websocket,
        {
            "type": "account_password_change_result",
            "request_id": packet.get("request_id"),
            "ok": ok,
            "reason": reason,
        },
    )
    if not ok:
        return

    for other_node, other_login in list(server.client_logins.items()):
        if (
            other_node == context.node_id
            or other_login != password_login
        ):
            continue
        other_socket = server.clients.get(other_node)
        if not other_socket:
            continue
        try:
            await send_json(
                other_socket,
                {
                    "type": "server_error",
                    "code": "account_password_changed",
                    "message": (
                        "The account password was changed from another "
                        "signed-in device."
                    ),
                },
            )
            await other_socket.close(
                code=4004,
                reason="account password changed",
            )
        except Exception as error:
            print(
                "Password change device close failed:",
                other_node,
                error,
            )


async def handle_active_device_action(server, packet, context):
    device_login = account_login(server, context.node_id)
    target_node = str(packet.get("target_node") or "").strip()
    action = str(packet.get("action") or "").strip().lower()

    if action == "revoke" and target_node == context.node_id:
        ok, reason = False, "cannot_revoke_current_device"
    else:
        ok, reason = server.update_account_device(
            device_login,
            target_node,
            action,
            packet.get("device_name"),
        )

    await send_json(
        context.websocket,
        {
            "type": "active_device_action_result",
            "request_id": packet.get("request_id"),
            "ok": ok,
            "reason": reason,
            "devices": server.get_account_devices(device_login),
        },
    )

    if not (ok and action == "revoke"):
        return
    target_socket = server.clients.get(target_node)
    if not target_socket:
        return
    try:
        await send_json(
            target_socket,
            {
                "type": "server_error",
                "code": "device_revoked",
                "message": (
                    "This device session was revoked from another signed-in "
                    "device."
                ),
            },
        )
        await target_socket.close(
            code=4003,
            reason="device session revoked",
        )
    except Exception as error:
        print("Device session close failed:", target_node, error)


async def handle_email_verification_request(server, packet, context):
    login = server.client_logins.get(context.node_id, "")
    if not login:
        await server.send_server_error(
            context.websocket,
            "authentication_failed",
            "Account session is unavailable",
        )
        return

    current_email = server.account_email(login)
    if current_email:
        await send_json(
            context.websocket,
            {
                "type": "email_verification_result",
                "ok": True,
                "complete": True,
                "email": server.mask_email(current_email),
            },
        )
        return

    email = server.normalize_email(packet.get("email"))
    challenge, reason = await server.issue_email_challenge_async(
        login,
        context.node_id,
        email,
        "binding",
    )
    response = {
        "type": "email_verification_result",
        "ok": bool(challenge),
        "complete": False,
    }
    if challenge:
        response.update(challenge)
    else:
        response.update(
            {
                "code": str(reason).split(":", 1)[0],
                "message": "Could not send the verification email",
            }
        )
    await send_json(context.websocket, response)


async def handle_email_verification_confirm(server, packet, context):
    login = server.client_logins.get(context.node_id, "")
    ok, reason, email = server.verify_email_challenge(
        packet.get("challenge_id"),
        login,
        context.node_id,
        packet.get("code"),
        "binding",
    )
    if ok:
        ok, reason = server.bind_account_email(
            login,
            email,
            context.node_id,
        )
    await send_json(
        context.websocket,
        {
            "type": "email_verification_result",
            "ok": ok,
            "complete": ok,
            "code": reason,
            "message": (
                "Email linked"
                if ok
                else "The verification code is invalid or expired"
            ),
            "email": server.mask_email(email) if ok else "",
        },
    )


async def handle_account_delete(server, packet, context):
    delete_login = server.client_logins.get(context.node_id, "")
    request_id = packet.get("request_id")
    ok, reason = server.delete_account(
        delete_login,
        packet.get("password"),
    )
    await send_json(
        context.websocket,
        {
            "type": "account_delete_result",
            "request_id": request_id,
            "ok": ok,
            "code": reason,
            "message": (
                "Account deleted"
                if ok
                else "Password is incorrect"
            ),
        },
    )
    if not ok:
        return

    await server.send_user_list()
    account_sockets = [
        client_socket
        for client_node, client_socket in server.clients.items()
        if server.client_logins.get(client_node) == delete_login
    ]
    service_sockets = [
        client_socket
        for client_node, client_socket in server.service_clients.items()
        if server.service_logins.get(client_node) == delete_login
    ]
    await asyncio.sleep(0.05)
    await asyncio.gather(
        *(
            client_socket.close(
                code=1000,
                reason="account deleted",
            )
            for client_socket in {
                *account_sockets,
                *service_sockets,
            }
        ),
        return_exceptions=True,
    )
    raise StopConnectionHandler()


def register_identity_commands(registry):
    registry.register("username_lookup", handle_username_lookup)
    registry.register("profile_update", handle_profile_update)
    registry.register("active_devices_request", handle_active_devices_request)
    registry.register(
        "account_password_change_request",
        handle_account_password_change,
    )
    registry.register(
        "active_device_action_request",
        handle_active_device_action,
    )


def register_identity_control_commands(registry):
    registry.register(
        "email_verification_request",
        handle_email_verification_request,
    )
    registry.register(
        "email_verification_confirm",
        handle_email_verification_confirm,
    )
    registry.register("account_delete_request", handle_account_delete)
