from network.client import send_packet


def forward_packet(
    discovery,
    my_node_id,
    packet
):
    
    print(
        "FORWARD:",
        packet["type"],
        packet.get("source_node"),
        "->",
        packet.get("destination_node"),
        "TTL:",
        packet.get("ttl")
    )

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

    print("USERS LIST:", users)

    for user in users:

        print("USER:", repr(user))

        node_id, name, ip, port = user

        print(
            "PARSED:",
            repr(node_id),
            repr(name),
            repr(ip),
            repr(port)
        )

        if node_id == my_node_id:
            continue

        if node_id == source_node:
            continue
        
        print(
            "FORWARD TO:",
            node_id,
            name,
            ip,
            port
        )

        send_packet(
            ip,
            port,
            packet
        )