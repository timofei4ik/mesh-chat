from copy import deepcopy


class UnsupportedShadowEvent(ValueError):
    pass


DELTA_SHADOW_EVENT_TYPES = frozenset(
    {
        "chat_message",
        "message_edit",
        "message_delete",
        "chat_delete",
        "message_pin",
        "message_reaction",
        "group_message",
        "group_update",
        "group_member_leave",
        "group_delete",
        "group_message_edit",
        "group_message_delete",
        "group_pin",
        "group_reaction",
        "story_update",
        "story_reaction",
        "story_delete",
    }
)

_DIRECT_FIELDS = (
    "sender_node",
    "receiver_node",
    "message",
    "reply_to_message_id",
    "reply_to_text",
    "chat_kind",
    "chat_id",
    "message_effect",
)
_GROUP_FIELDS = (
    "group_name",
    "members",
    "owner_node",
    "admins",
    "is_channel",
    "group_about",
    "group_avatar_data",
    "comments_enabled",
)
_GROUP_MESSAGE_FIELDS = (
    "group_id",
    "group_name",
    "sender_node",
    "message",
    "reply_to_message_id",
    "reply_to_text",
    "members",
    "group_key_id",
    "message_effect",
    "is_channel_comment",
)


def _text(value, default=""):
    return str(value if value is not None else default)


def _sorted_texts(value):
    if not isinstance(value, list):
        return []
    return sorted({_text(item) for item in value if _text(item)})


def _canonical_direct(item):
    return {
        "sender_node": _text(
            item.get("sender_node") or item.get("source_node")
        ),
        "receiver_node": _text(
            item.get("receiver_node") or item.get("destination_node")
        ),
        "message": _text(item.get("message")),
        "reply_to_message_id": _text(item.get("reply_to_message_id")),
        "reply_to_text": _text(item.get("reply_to_text")),
        "chat_kind": _text(item.get("chat_kind"), "normal") or "normal",
        "chat_id": _text(item.get("chat_id")),
        "message_effect": (
            _text(item.get("message_effect"), "none") or "none"
        ),
    }


def _canonical_group(item):
    owner_node = _text(item.get("owner_node"))
    return {
        "group_name": _text(item.get("group_name")),
        "members": _sorted_texts(item.get("members")),
        "owner_node": owner_node,
        "admins": [
            admin
            for admin in _sorted_texts(item.get("admins"))
            if admin != owner_node
        ],
        "is_channel": item.get("is_channel") is True,
        "group_about": _text(item.get("group_about")),
        "group_avatar_data": _text(item.get("group_avatar_data")),
        "comments_enabled": item.get("comments_enabled") is not False,
    }


def _canonical_group_message(item):
    reply_id = _text(item.get("reply_to_message_id"))
    return {
        "group_id": _text(item.get("group_id")),
        "group_name": _text(item.get("group_name")),
        "sender_node": _text(
            item.get("sender_node") or item.get("source_node")
        ),
        "message": _text(item.get("message")),
        "reply_to_message_id": reply_id,
        "reply_to_text": _text(item.get("reply_to_text")),
        "members": _sorted_texts(item.get("members")),
        "group_key_id": _text(item.get("group_key_id")),
        "message_effect": (
            _text(item.get("message_effect"), "none") or "none"
        ),
        "is_channel_comment": (
            item.get("is_channel_comment") is True or bool(reply_id)
        ),
    }


def _canonical_story(item):
    story = deepcopy(item)
    story.pop("created_at", None)
    story["id"] = _text(story.get("id"))
    story["owner_node"] = _text(story.get("owner_node"))
    reactions = story.get("reactions")
    if isinstance(reactions, dict):
        story["reactions"] = {
            _text(reaction): _sorted_texts(nodes)
            for reaction, nodes in reactions.items()
            if _text(reaction)
        }
    story["liked_by_node_ids"] = _sorted_texts(
        story.get("liked_by_node_ids")
    )
    story["viewed_by_node_ids"] = _sorted_texts(
        story.get("viewed_by_node_ids")
    )
    return story


def canonical_sync_v2_state(snapshot):
    snapshot = snapshot if isinstance(snapshot, dict) else {}
    state = {
        "direct_messages": {},
        "groups": {},
        "group_messages": {},
        "reactions": {},
        "pins": {},
        "stories": {},
    }
    for item in snapshot.get("direct_messages") or []:
        if not isinstance(item, dict):
            continue
        item_id = _text(item.get("message_id"))
        if item_id:
            state["direct_messages"][item_id] = _canonical_direct(item)
    for item in snapshot.get("groups") or []:
        if not isinstance(item, dict):
            continue
        item_id = _text(item.get("group_id"))
        if item_id:
            state["groups"][item_id] = _canonical_group(item)
    for item in snapshot.get("group_messages") or []:
        if not isinstance(item, dict):
            continue
        item_id = _text(item.get("message_id"))
        if item_id:
            state["group_messages"][item_id] = _canonical_group_message(item)
    for item in snapshot.get("reactions") or []:
        if not isinstance(item, dict):
            continue
        key = (
            _text(item.get("scope")),
            _text(item.get("message_id")),
            _text(item.get("reactor_node")),
            _text(item.get("reaction")),
        )
        if all(key):
            state["reactions"]["\u001f".join(key)] = True
    for item in snapshot.get("pins") or []:
        if not isinstance(item, dict):
            continue
        scope = _text(item.get("scope"))
        message_id = _text(item.get("message_id"))
        if scope and message_id:
            state["pins"][f"{scope}\u001f{message_id}"] = {
                "pinner_node": _text(item.get("pinner_node")),
                "text": _text(item.get("text")),
                "group_key_id": _text(item.get("group_key_id")),
            }
    for item in snapshot.get("stories") or []:
        if not isinstance(item, dict):
            continue
        item_id = _text(item.get("id"))
        if item_id:
            state["stories"][item_id] = _canonical_story(item)
    return state


def _remove_message_relations(state, message_ids):
    message_ids = {_text(item) for item in message_ids if _text(item)}
    if not message_ids:
        return
    state["reactions"] = {
        key: value
        for key, value in state["reactions"].items()
        if key.split("\u001f")[1] not in message_ids
    }
    state["pins"] = {
        key: value
        for key, value in state["pins"].items()
        if key.split("\u001f")[1] not in message_ids
    }


def _remove_group(state, group_id):
    state["groups"].pop(group_id, None)
    removed = {
        message_id
        for message_id, message in state["group_messages"].items()
        if message.get("group_id") == group_id
    }
    state["group_messages"] = {
        message_id: message
        for message_id, message in state["group_messages"].items()
        if message_id not in removed
    }
    state["reactions"] = {
        key: value
        for key, value in state["reactions"].items()
        if not key.startswith(f"group:{group_id}\u001f")
        and key.split("\u001f")[1] not in removed
    }
    state["pins"] = {
        key: value
        for key, value in state["pins"].items()
        if not key.startswith(f"group:{group_id}\u001f")
        and key.split("\u001f")[1] not in removed
    }


def apply_sync_v2_delta_shadow(snapshot, events, node_id=""):
    state = canonical_sync_v2_state(snapshot)
    normalized_node = _text(node_id)
    for event in events:
        if not isinstance(event, dict):
            raise UnsupportedShadowEvent("delta event is not an object")
        packet_type = _text(
            event.get("packet_type")
            or (event.get("payload") or {}).get("type")
        )
        if packet_type not in DELTA_SHADOW_EVENT_TYPES:
            raise UnsupportedShadowEvent(packet_type or "missing event type")
        payload = event.get("payload")
        if not isinstance(payload, dict):
            raise UnsupportedShadowEvent(f"{packet_type}: invalid payload")

        if packet_type == "chat_message":
            message_id = _text(
                payload.get("message_id") or payload.get("packet_id")
            )
            if message_id:
                state["direct_messages"][message_id] = _canonical_direct(payload)
        elif packet_type == "message_edit":
            message_id = _text(payload.get("message_id"))
            message = state["direct_messages"].get(message_id)
            if message is not None:
                message["message"] = _text(
                    payload.get("file_caption")
                    if payload.get("file_caption") is not None
                    else payload.get("message")
                )
        elif packet_type == "message_delete":
            message_id = _text(payload.get("message_id"))
            state["direct_messages"].pop(message_id, None)
            _remove_message_relations(state, {message_id})
        elif packet_type == "chat_delete":
            chat_id = _text(payload.get("chat_id"))
            source = _text(payload.get("source_node"))
            destination = _text(
                payload.get("chat_node_id") or payload.get("destination_node")
            )
            removed = {
                message_id
                for message_id, message in state["direct_messages"].items()
                if (
                    (chat_id and message.get("chat_id") == chat_id)
                    or (
                        not chat_id
                        and {message.get("sender_node"), message.get("receiver_node")}
                        == {source, destination}
                    )
                )
            }
            for message_id in removed:
                state["direct_messages"].pop(message_id, None)
            _remove_message_relations(state, removed)
        elif packet_type == "group_update":
            group_id = _text(payload.get("group_id"))
            members = _sorted_texts(payload.get("members"))
            if group_id:
                if normalized_node and normalized_node not in members:
                    _remove_group(state, group_id)
                else:
                    state["groups"][group_id] = _canonical_group(payload)
        elif packet_type == "group_member_leave":
            group_id = _text(payload.get("group_id"))
            leaver = _text(
                payload.get("leaver_node") or payload.get("source_node")
            )
            group = state["groups"].get(group_id)
            if group is not None:
                if normalized_node and leaver == normalized_node:
                    _remove_group(state, group_id)
                else:
                    group["members"] = [
                        member for member in group["members"] if member != leaver
                    ]
                    group["admins"] = [
                        admin for admin in group["admins"] if admin != leaver
                    ]
        elif packet_type == "group_delete":
            _remove_group(state, _text(payload.get("group_id")))
        elif packet_type == "group_message":
            message_id = _text(
                payload.get("group_message_id") or payload.get("packet_id")
            )
            if message_id:
                state["group_messages"][message_id] = (
                    _canonical_group_message(payload)
                )
        elif packet_type == "group_message_edit":
            message_id = _text(payload.get("group_message_id"))
            message = state["group_messages"].get(message_id)
            if message is not None:
                message["message"] = _text(payload.get("message"))
                if payload.get("group_key_id") is not None:
                    message["group_key_id"] = _text(
                        payload.get("group_key_id")
                    )
        elif packet_type == "group_message_delete":
            message_id = _text(payload.get("group_message_id"))
            state["group_messages"].pop(message_id, None)
            _remove_message_relations(state, {message_id})
        elif packet_type in {"message_reaction", "group_reaction"}:
            scope = (
                f"group:{_text(payload.get('group_id'))}"
                if packet_type == "group_reaction"
                else "direct"
            )
            message_id = _text(
                payload.get("group_message_id") or payload.get("message_id")
            )
            key = "\u001f".join(
                (
                    scope,
                    message_id,
                    _text(payload.get("source_node")),
                    _text(payload.get("reaction")),
                )
            )
            if all(key.split("\u001f")):
                state["reactions"][key] = True
        elif packet_type in {"message_pin", "group_pin"}:
            message_id = _text(payload.get("message_id"))
            scope = (
                f"group:{_text(payload.get('group_id'))}"
                if packet_type == "group_pin"
                else "chat:" + ":".join(
                    sorted(
                        (
                            _text(payload.get("source_node")),
                            _text(payload.get("destination_node")),
                        )
                    )
                )
            )
            key = f"{scope}\u001f{message_id}"
            if payload.get("action") == "unpin":
                state["pins"].pop(key, None)
            elif message_id:
                state["pins"][key] = {
                    "pinner_node": _text(payload.get("source_node")),
                    "text": _text(payload.get("text")),
                    "group_key_id": _text(payload.get("group_key_id")),
                }
        elif packet_type == "story_update":
            raw_story = payload.get("story")
            if isinstance(raw_story, dict):
                story_id = _text(
                    raw_story.get("id") or payload.get("packet_id")
                )
                previous = state["stories"].get(story_id, {})
                story = deepcopy(raw_story)
                story["id"] = story_id
                story["owner_node"] = _text(
                    story.get("owner_node") or payload.get("source_node")
                )
                for engagement_key in (
                    "reactions",
                    "liked_by_node_ids",
                    "viewed_by_node_ids",
                ):
                    if engagement_key not in story and engagement_key in previous:
                        story[engagement_key] = previous[engagement_key]
                state["stories"][story_id] = _canonical_story(story)
        elif packet_type == "story_reaction":
            story_id = _text(payload.get("story_id"))
            story = state["stories"].get(story_id)
            if story is not None:
                reactor = _text(payload.get("source_node"))
                reaction = _text(payload.get("reaction"), "heart") or "heart"
                reactions = story.setdefault("reactions", {})
                if payload.get("replace_existing") is True:
                    for nodes in reactions.values():
                        if isinstance(nodes, list) and reactor in nodes:
                            nodes.remove(reactor)
                nodes = reactions.setdefault(reaction, [])
                if payload.get("liked") is False:
                    if reactor in nodes:
                        nodes.remove(reactor)
                elif reactor and reactor not in nodes:
                    nodes.append(reactor)
                    nodes.sort()
                story["liked_by_node_ids"] = list(
                    reactions.get("heart", [])
                )
        elif packet_type == "story_delete":
            state["stories"].pop(_text(payload.get("story_id")), None)
    return state


def compare_sync_v2_shadow(snapshot, events, target_snapshot, node_id=""):
    shadow = apply_sync_v2_delta_shadow(snapshot, events, node_id=node_id)
    target = canonical_sync_v2_state(target_snapshot)
    mismatches = {
        section: {
            "shadow": shadow[section],
            "snapshot": target[section],
        }
        for section in shadow
        if shadow[section] != target[section]
    }
    return {
        "ok": not mismatches,
        "mismatches": mismatches,
        "shadow": shadow,
        "snapshot": target,
    }
