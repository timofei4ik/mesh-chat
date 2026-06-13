import socket
from network.message_id import generate_message_id
import json


def send_packet(
        ip,
        port,
        packet
):
    
    try:

        sock = socket.socket(
            socket.AF_INET,
            socket.SOCK_STREAM
        )

        sock.connect(
            (
                ip,
                port
            )
        )

        sock.send(
            (json.dumps(packet) + "\n").encode()
        )

        sock.close()

    except Exception as e:

        import traceback

        traceback.print_exc()

        print(
            "Send error:",
            e
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