from copy import deepcopy


MESHPRO_SCHEMA_VERSION = 1
MESHPRO_CATALOG_VERSION = "2026-07-16.10"
MESHPRO_PRODUCT = "meshpro"

ROLLOUT_AVAILABLE = "available"
ROLLOUT_PLANNED = "planned"


_FEATURES = {
    "meshprivacy_vpn": {
        "application": "meshprivacy",
        "category": "privacy",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "premium_badge": {
        "application": "meshchat",
        "category": "profile",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "animated_avatar": {
        "application": "meshchat",
        "category": "profile",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "profile_background": {
        "application": "meshchat",
        "category": "profile",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "profile_effect": {
        "application": "meshchat",
        "category": "profile",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "profile_glow": {
        "application": "meshchat",
        "category": "profile",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "emoji_status": {
        "application": "meshchat",
        "category": "profile",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "custom_accent": {
        "application": "meshchat",
        "category": "appearance",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "animated_chat_backgrounds": {
        "application": "meshchat",
        "category": "appearance",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "per_chat_theme": {
        "application": "meshchat",
        "category": "appearance",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "custom_message_bubbles": {
        "application": "meshchat",
        "category": "appearance",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "story_hd": {
        "application": "meshchat",
        "category": "stories",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "story_extended_video": {
        "application": "meshchat",
        "category": "stories",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "story_server_archive": {
        "application": "meshchat",
        "category": "stories",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "story_extra_reactions": {
        "application": "meshchat",
        "category": "stories",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "animated_stickers_plus": {
        "application": "meshchat",
        "category": "stickers",
        "rollout": ROLLOUT_PLANNED,
    },
    "custom_quick_reactions": {
        "application": "meshchat",
        "category": "stickers",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "photo_to_sticker": {
        "application": "meshchat",
        "category": "stickers",
        "rollout": ROLLOUT_PLANNED,
    },
    "call_noise_suppression_plus": {
        "application": "meshchat",
        "category": "calls",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "call_hd_audio": {
        "application": "meshchat",
        "category": "calls",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "call_screen_share": {
        "application": "meshchat",
        "category": "calls",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "call_recording": {
        "application": "meshchat",
        "category": "calls",
        "rollout": ROLLOUT_PLANNED,
    },
    "call_group_plus": {
        "application": "meshchat",
        "category": "calls",
        "rollout": ROLLOUT_PLANNED,
    },
    "meshdrop_large_files": {
        "application": "meshdrop",
        "category": "files",
        "rollout": ROLLOUT_PLANNED,
    },
    "meshdrop_folder_transfer": {
        "application": "meshdrop",
        "category": "files",
        "rollout": ROLLOUT_PLANNED,
    },
    "meshdrop_resume": {
        "application": "meshdrop",
        "category": "files",
        "rollout": ROLLOUT_PLANNED,
    },
    "advanced_chat_folders": {
        "application": "meshchat",
        "category": "organization",
        "rollout": ROLLOUT_PLANNED,
    },
    "channel_scheduled_posts": {
        "application": "meshchat",
        "category": "channels",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "scheduled_messages": {
        "application": "meshchat",
        "category": "organization",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "recurring_reminders": {
        "application": "meshchat",
        "category": "organization",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "channel_analytics": {
        "application": "meshchat",
        "category": "channels",
        "rollout": ROLLOUT_PLANNED,
    },
    "channel_advanced_roles": {
        "application": "meshchat",
        "category": "channels",
        "rollout": ROLLOUT_PLANNED,
    },
    "channel_spam_filter": {
        "application": "meshchat",
        "category": "channels",
        "rollout": ROLLOUT_PLANNED,
    },
    "ai_text_rewrite": {
        "application": "meshchat",
        "category": "ai",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_voice_transcription": {
        "application": "meshchat",
        "category": "ai",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_chat_summary": {
        "application": "meshchat",
        "category": "ai",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_image_ocr": {
        "application": "meshchat",
        "category": "ai",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_smart_replies": {
        "application": "meshchat",
        "category": "ai",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_person_memory": {
        "application": "meshchat",
        "category": "ai",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_call_summary": {
        "application": "meshchat",
        "category": "ai",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_message_translation": {
        "application": "meshchat",
        "category": "ai",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "multi_device_plus": {
        "application": "meshchat",
        "category": "devices",
        "rollout": ROLLOUT_AVAILABLE,
    },
    "remote_session_management": {
        "application": "meshchat",
        "category": "devices",
        "rollout": ROLLOUT_AVAILABLE,
    },
}


_LIMITS = {
    "active_devices": {
        "unit": "count",
        "free": 3,
        "meshpro": 10,
        "rollout": ROLLOUT_PLANNED,
    },
    "chat_folders": {
        "unit": "count",
        "free": 3,
        "meshpro": 50,
        "rollout": ROLLOUT_PLANNED,
    },
    "favorite_stickers": {
        "unit": "count",
        "free": 100,
        "meshpro": 1000,
        "rollout": ROLLOUT_PLANNED,
    },
    "quick_reactions": {
        "unit": "count",
        "free": 4,
        "meshpro": 20,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "story_video_seconds": {
        "unit": "seconds",
        "free": 30,
        "meshpro": 120,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "story_parallel_items": {
        "unit": "count",
        "free": 3,
        "meshpro": 20,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "group_call_participants": {
        "unit": "count",
        "free": 3,
        "meshpro": 10,
        "rollout": ROLLOUT_PLANNED,
    },
    "file_transfer_bytes": {
        "unit": "bytes",
        "free": 64 * 1024 * 1024,
        "meshpro": 2 * 1024 * 1024 * 1024,
        "rollout": ROLLOUT_PLANNED,
    },
    "scheduled_channel_posts": {
        "unit": "count",
        "free": 0,
        "meshpro": 100,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "scheduled_messages": {
        "unit": "count",
        "free": 0,
        "meshpro": 200,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_text_rewrites_month": {
        "unit": "count_per_month",
        "free": 0,
        "meshpro": 50,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_transcription_minutes_month": {
        "unit": "minutes_per_month",
        "free": 0,
        "meshpro": 60,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_chat_summaries_month": {
        "unit": "count_per_month",
        "free": 0,
        "meshpro": 30,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_image_ocr_month": {
        "unit": "count_per_month",
        "free": 0,
        "meshpro": 100,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_smart_replies_month": {
        "unit": "count_per_month",
        "free": 0,
        "meshpro": 100,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_person_memory_month": {
        "unit": "count_per_month",
        "free": 0,
        "meshpro": 60,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_call_summaries_month": {
        "unit": "count_per_month",
        "free": 0,
        "meshpro": 30,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "ai_message_translations_month": {
        "unit": "count_per_month",
        "free": 0,
        "meshpro": 150,
        "rollout": ROLLOUT_AVAILABLE,
    },
    "custom_themes": {
        "unit": "count",
        "free": 0,
        "meshpro": 20,
        "rollout": ROLLOUT_PLANNED,
    },
    "server_story_archive_days": {
        "unit": "days",
        "free": 0,
        "meshpro": 365,
        "rollout": ROLLOUT_AVAILABLE,
    },
}


def build_meshpro_catalog():
    return {
        "schema_version": MESHPRO_SCHEMA_VERSION,
        "catalog_version": MESHPRO_CATALOG_VERSION,
        "product": MESHPRO_PRODUCT,
        "features": deepcopy(_FEATURES),
        "limits": deepcopy(_LIMITS),
    }


def build_meshpro_entitlements(active):
    active = bool(active)
    features = {
        feature_id: (
            active and definition["rollout"] == ROLLOUT_AVAILABLE
        )
        for feature_id, definition in _FEATURES.items()
    }
    limits = {
        limit_id: (
            definition["meshpro"]
            if active and definition["rollout"] == ROLLOUT_AVAILABLE
            else definition["free"]
        )
        for limit_id, definition in _LIMITS.items()
    }
    return {
        "schema_version": MESHPRO_SCHEMA_VERSION,
        "catalog_version": MESHPRO_CATALOG_VERSION,
        "product": MESHPRO_PRODUCT,
        "active": active,
        "features": features,
        "limits": limits,
    }
