import uuid

try:
    from server.server_command_bus import account_login, send_json
except ModuleNotFoundError:
    from server_command_bus import account_login, send_json


SUBJECT_TYPES = {"message", "comment", "story", "profile", "group", "channel"}
REASONS = {"spam", "harassment", "violence", "sexual", "scam", "other"}


async def handle_moderation_report(server, packet, context):
    request_id = str(packet.get("request_id") or packet.get("packet_id") or "")
    reporter_login = account_login(server, context.node_id)
    subject_type = str(packet.get("subject_type") or "").strip().lower()
    reason = str(packet.get("reason") or "").strip().lower()
    subject_id = str(packet.get("subject_id") or "").strip()
    if not reporter_login:
        error = "authentication_required"
    elif subject_type not in SUBJECT_TYPES:
        error = "invalid_subject_type"
    elif reason not in REASONS:
        error = "invalid_reason"
    elif not subject_id or len(subject_id) > 256:
        error = "invalid_subject_id"
    else:
        error = ""
    if error:
        await send_json(
            context.websocket,
            {
                "type": "moderation_report_result", "request_id": request_id,
                "ok": False, "error": error,
            },
        )
        return

    snapshot = packet.get("snapshot")
    if not isinstance(snapshot, dict):
        snapshot = {}
    snapshot = {
        str(key)[:64]: value
        for key, value in list(snapshot.items())[:16]
        if isinstance(value, (str, int, float, bool)) or value is None
    }
    report_id = str(uuid.uuid4())
    with server.unit_of_work_factory(write=True) as unit_of_work:
        unit_of_work.moderation.create_report(
            {
                "report_id": report_id,
                "reporter_login": reporter_login,
                "reporter_node": context.node_id,
                "subject_type": subject_type,
                "subject_id": subject_id,
                "conversation_id": str(packet.get("conversation_id") or "")[:256],
                "target_login": str(packet.get("target_login") or "")[:128].lower(),
                "reason": reason,
                "details": str(packet.get("details") or "")[:2000],
                "snapshot": snapshot,
                "priority": 1 if reason in {"violence", "sexual"} else 0,
            }
        )
    await send_json(
        context.websocket,
        {
            "type": "moderation_report_result", "request_id": request_id,
            "ok": True, "report_id": report_id,
        },
    )


def register_moderation_commands(registry):
    registry.register("moderation_report", handle_moderation_report)
