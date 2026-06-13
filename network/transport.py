class TransportError(Exception):

    pass


class Transport:

    name = "base"

    def send_packet(
        self,
        peer,
        packet
    ):

        raise NotImplementedError
