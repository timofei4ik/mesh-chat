import time


class RoutingTable:

    def __init__(self):

        self.routes = {}

    def update_route(
        self,
        node_id,
        next_hop_ip,
        next_hop_port,
        hops
    ):

        current = self.routes.get(
            node_id
        )

        if current:

            if current["hops"] <= hops:
                return

        self.routes[node_id] = {

            "ip": next_hop_ip,

            "port": next_hop_port,

            "hops": hops,

            "last_seen": time.time()
        }

    def get_route(
        self,
        node_id
    ):

        return self.routes.get(
            node_id
        )

    def cleanup(self):

        now = time.time()

        for node_id in list(
            self.routes.keys()
        ):

            if now - self.routes[node_id]["last_seen"] > 30:

                del self.routes[
                    node_id
                ]

    def get_all_routes(self):

        return self.routes