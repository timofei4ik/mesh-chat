import time


class PacketCache:

    def __init__(self):

        self.packets = {}

    def add(
        self,
        packet_id
    ):

        self.packets[
            packet_id
        ] = time.time()

    def exists(
        self,
        packet_id
    ):

        return packet_id in self.packets

    def cleanup(self):

        now = time.time()

        remove = []

        for packet_id, created in self.packets.items():

            if now - created > 300:

                remove.append(
                    packet_id
                )

        for packet_id in remove:

            del self.packets[
                packet_id
            ]