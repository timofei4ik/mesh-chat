from network.message_id import generate_message_id
from version import MIN_SUPPORTED_PROTOCOL_VERSION, PROTOCOL_VERSION


DEFAULT_TTL = 5


def base_packet(
    packet_type,
    source_node,
    destination_node=None,
    packet_id=None,
    ttl=DEFAULT_TTL
):

    packet = {
        "protocol_version": PROTOCOL_VERSION,
        "min_protocol_version": MIN_SUPPORTED_PROTOCOL_VERSION,
        "packet_id": packet_id or generate_message_id(),
        "type": packet_type,
        "source_node": source_node,
        "ttl": ttl
    }

    if destination_node:

        packet["destination_node"] = destination_node

    return packet


def chat_message_packet(
    source_node,
    destination_node,
    sender,
    message,
    packet_id=None
):

    packet = base_packet(
        "chat_message",
        source_node,
        destination_node,
        packet_id
    )

    packet.update(
        {
            "sender": sender,
            "message": message
        }
    )

    return packet


def message_received_packet(
    source_node,
    destination_node,
    message_id
):

    packet = base_packet(
        "message_received",
        source_node,
        destination_node
    )

    packet["message_id"] = message_id

    return packet


def group_message_packet(
    source_node,
    destination_node,
    sender,
    group_id,
    group_name,
    members,
    message,
    group_message_id,
    owner_node=None,
    admins=None
):

    packet = base_packet(
        "group_message",
        source_node,
        destination_node
    )

    packet.update(
        {
            "group_id": group_id,
            "group_name": group_name,
            "group_message_id": group_message_id,
            "sender": sender,
            "members": members,
            "owner_node": owner_node,
            "admins": admins or [],
            "message": message
        }
    )

    return packet


def group_update_packet(
    source_node,
    destination_node,
    group_id,
    group_name,
    members,
    owner_node=None,
    admins=None
):

    packet = base_packet(
        "group_update",
        source_node,
        destination_node
    )

    packet.update(
        {
            "group_id": group_id,
            "group_name": group_name,
            "members": members,
            "owner_node": owner_node,
            "admins": admins or []
        }
    )

    return packet


def group_delete_packet(
    source_node,
    destination_node,
    group_id
):

    packet = base_packet(
        "group_delete",
        source_node,
        destination_node
    )

    packet["group_id"] = group_id

    return packet
