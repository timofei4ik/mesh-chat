from network.client import send_packet


def forward_packet(
    discovery,
    my_node_id,
    packet
):

    ttl = packet.get(
        "ttl",
        0
    )

    if ttl <= 0:
        return

    packet["ttl"] = ttl - 1

    source_node = packet.get(
        "source_node"
    )

    users = discovery.get_users()

    for user in users:

        node_id, name, ip, port = user

        if node_id == my_node_id:
            continue

        if node_id == source_node:
            continue

        send_packet(
            ip,
            port,
            packet
        )
