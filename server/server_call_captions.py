"""Short-lived, explicitly consented group-caption sponsorship.

The database is shared by relay workers. No client-selected account is ever
passed to the AI quota code without checking this lease and current membership.
"""

import time
import uuid

try:
    from server.server_command_bus import account_login, send_json
except ModuleNotFoundError:
    from server_command_bus import account_login, send_json

LEASE_SECONDS = 90


def caption_session(server, call_id):
    row = server.db.execute(
        "SELECT sponsor_node, group_id, expires_at, session_id FROM call_caption_sessions WHERE call_id=?",
        (call_id,),
    ).fetchone()
    if not row or row[2] <= int(time.time()):
        return None
    return row


def caption_billing_login(server, call_id, node_id, session_id):
    row = caption_session(server, call_id)
    if not row or row[3] != session_id:
        return ""
    sponsor, group_id, _, _ = row
    allowed = set(server.get_group_delivery_nodes(group_id))
    if node_id not in allowed or sponsor not in allowed:
        return ""
    member = server.db.execute(
        "SELECT consent FROM call_caption_members WHERE call_id=? AND node_id=?",
        (call_id, node_id),
    ).fetchone()
    login = server.get_login_by_node(sponsor)
    if not member or member[0] != 1 or not login or not server.subscription_feature_enabled(login, "ai_voice_transcription"):
        return ""
    return login


async def _notify(server, call_id, sponsor, group_id, expires, session_id, members, enabled=True):
    try:
        from server.server_calls import route_call_signal
    except ModuleNotFoundError:
        from server_calls import route_call_signal
    for node, consent, revision in members:
        await route_call_signal(server, {
            "type": "call_caption_session",
            "source_node": "SERVER",
            "destination_node": node,
            "call_id": call_id,
            "group_id": group_id,
            "sponsor_node": sponsor,
            "enabled": enabled,
            "consent": consent,
            "revision": revision,
            "expires_at": expires,
            "session_id": session_id,
        })


async def handle_caption_session(server, packet, context):
    call_id = str(packet.get("call_id") or "").strip()
    group_id = str(packet.get("group_id") or "").strip()
    action = packet.get("action")
    response = {"type": "call_caption_session_result", "request_id": packet.get("request_id"), "call_id": call_id}

    async def fail(error):
        await send_json(context.websocket, {**response, "ok": False, "error": error})
        return True

    if not call_id or len(call_id) > 128 or not group_id or len(group_id) > 256:
        return await fail("invalid_call")
    if action not in {"start", "heartbeat", "stop", "join", "decline"}:
        return await fail("invalid_action")
    allowed = set(server.get_group_delivery_nodes(group_id))
    node = context.node_id
    if node not in allowed:
        return await fail("group_call_forbidden")
    now = int(time.time())
    server.db.execute("DELETE FROM call_caption_members WHERE call_id IN (SELECT call_id FROM call_caption_sessions WHERE expires_at<=?)", (now,))
    server.db.execute("DELETE FROM call_caption_sessions WHERE expires_at<=?", (now,))
    server.db.commit()
    row = caption_session(server, call_id)
    if action == "start" and row is None:
        login = account_login(server, node)
        if not login or not server.subscription_feature_enabled(login, "ai_voice_transcription"):
            return await fail("meshpro_required")
        members = packet.get("members")
        if not isinstance(members, list) or not 1 <= len(members) <= 8 or any(not isinstance(member, str) or member not in allowed for member in members):
            return await fail("invalid_members")
        members = set(members) | {node}
        if len(members) > 8:
            return await fail("invalid_members")
        # Unique sponsor_node prevents opening unbounded sponsored sessions.
        server.db.execute(
            "INSERT INTO call_caption_sessions(call_id,sponsor_node,group_id,expires_at,session_id) VALUES(?,?,?,?,?) ON CONFLICT DO NOTHING",
            (call_id, node, group_id, now + LEASE_SECONDS, uuid.uuid4().hex),
        )
        row = caption_session(server, call_id)
        if row and row[0] == node and row[1] == group_id:
            for member in members:
                server.db.execute(
                    "INSERT INTO call_caption_members(call_id,node_id,consent) VALUES(?,?,?) ON CONFLICT DO NOTHING",
                    (call_id, member, 1 if member == node else 0),
                )
        server.db.commit()
    if not row or row[1] != group_id:
        return await fail("caption_session_unavailable")
    sponsor, _, expires, session_id = row
    if action != "start" and packet.get("session_id") != session_id:
        return await fail("caption_session_expired")
    member = server.db.execute("SELECT consent FROM call_caption_members WHERE call_id=? AND node_id=?", (call_id, node)).fetchone()
    if member is None:
        return await fail("caption_session_forbidden")
    if action in {"start", "heartbeat", "stop"} and sponsor != node:
        return await fail("caption_session_owned_by_peer")
    if action in {"start", "heartbeat"}:
        login = account_login(server, node)
        if not login or not server.subscription_feature_enabled(login, "ai_voice_transcription"):
            return await fail("meshpro_required")
        expires = now + LEASE_SECONDS
        server.db.execute("UPDATE call_caption_sessions SET expires_at=? WHERE call_id=? AND sponsor_node=?", (expires, call_id, node))
    elif action in {"join", "decline"}:
        server.db.execute("UPDATE call_caption_members SET consent=?,revision=revision+1 WHERE call_id=? AND node_id=?", (1 if action == "join" else -1, call_id, node))
    members = server.db.execute("SELECT node_id,consent,revision FROM call_caption_members WHERE call_id=?", (call_id,)).fetchall()
    if action == "stop":
        server.db.execute("DELETE FROM call_caption_members WHERE call_id=?", (call_id,))
        server.db.execute("DELETE FROM call_caption_sessions WHERE call_id=? AND sponsor_node=?", (call_id, node))
    server.db.commit()
    await send_json(context.websocket, {**response, "ok": True})
    targets = members if action in {"start", "heartbeat", "stop"} else [entry for entry in members if entry[0] == node]
    await _notify(server, call_id, sponsor, group_id, expires, session_id, targets, enabled=action != "stop")
    return True
