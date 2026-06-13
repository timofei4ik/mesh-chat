from network.message_id import generate_message_id
from network.tcp_transport import TcpTransport


tcp_transport = TcpTransport()


def send_packet(
        ip,
        port,
        packet
):

    return tcp_transport.send_packet(
        {
            "ip": ip,

            "port": port
        },
        packet
    )

def send_chat_response(
    ip,
    port,
    accepted,
    source_node,
    destination_node
):


    packet = {

        "packet_id": generate_message_id(),

        "type": "chat_response",

        "accepted": accepted,

        "source_node": source_node,

        "destination_node": destination_node,

        "ttl": 5
    }


    send_packet(
        ip,
        port,
        packet
    )
