try:
    from server.server_command_bus import send_json
except ModuleNotFoundError:
    from server_command_bus import send_json


AI_COMMANDS = {
    "ai_text_rewrite_request": {
        "method": "rewrite_text_with_ai",
        "response_type": "ai_text_rewrite_result",
        "fields": ("text", "style"),
    },
    "ai_message_translation_request": {
        "method": "translate_message_with_ai",
        "response_type": "ai_message_translation_result",
        "fields": ("text", "target_language"),
    },
    "ai_chat_summary_request": {
        "method": "summarize_chat_with_ai",
        "response_type": "ai_chat_summary_result",
        "fields": ("messages",),
    },
    "ai_person_memory_request": {
        "method": "answer_person_memory_with_ai",
        "response_type": "ai_person_memory_result",
        "fields": ("question", "messages"),
    },
    "ai_call_summary_request": {
        "method": "summarize_call_notes_with_ai",
        "response_type": "ai_call_summary_result",
        "fields": ("notes",),
    },
    "ai_voice_transcription_request": {
        "method": "transcribe_voice_with_ai",
        "response_type": "ai_voice_transcription_result",
        "fields": (
            "message_id",
            "filename",
            "audio_base64",
            "duration_seconds",
        ),
        "response_fields": ("message_id",),
    },
    "ai_image_ocr_request": {
        "method": "extract_image_text_with_ai",
        "response_type": "ai_image_ocr_result",
        "fields": ("message_id", "filename", "image_base64"),
        "response_fields": ("message_id",),
    },
    "ai_smart_replies_request": {
        "method": "suggest_replies_with_ai",
        "response_type": "ai_smart_replies_result",
        "fields": ("messages",),
    },
}


async def handle_ai_request(server, packet, context):
    command = AI_COMMANDS[packet["type"]]
    authenticated_login = server.client_logins.get(context.node_id)
    method = getattr(server, command["method"])
    result = await method(
        authenticated_login,
        *(packet.get(field) for field in command["fields"]),
    )
    response = {
        "type": command["response_type"],
        "request_id": packet.get("request_id"),
    }
    for field in command.get("response_fields", ()):
        response[field] = packet.get(field)
    response.update(result)
    await send_json(context.websocket, response)


def register_ai_commands(registry):
    for packet_type in AI_COMMANDS:
        registry.register(packet_type, handle_ai_request)
