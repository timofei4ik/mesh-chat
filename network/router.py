class Router:

    def __init__(
        self,
        node_id
    ):

        self.node_id = node_id

    def is_for_me(
        self,
        packet
    ):

        destination = packet.get(
            "destination_node"
        )

        return (
            destination == self.node_id
        )

    def should_forward(
        self,
        packet
    ):

        destination = packet.get(
            "destination_node"
        )

        return (
            destination != self.node_id
        )

    def decrease_ttl(
        self,
        packet
    ):

        ttl = packet.get(
            "ttl",
            0
        )

        ttl -= 1

        packet["ttl"] = ttl

        return ttl > 0