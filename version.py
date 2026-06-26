APP_VERSION = "0.9"
PROTOCOL_VERSION = 5
MIN_SUPPORTED_PROTOCOL_VERSION = 5


def protocol_compatibility(peer_protocol, peer_min_protocol=None):
    try:
        peer_protocol = int(peer_protocol)
    except (TypeError, ValueError):
        return False, "missing protocol version"

    try:
        peer_min_protocol = int(
            peer_min_protocol
            if peer_min_protocol is not None
            else peer_protocol
        )
    except (TypeError, ValueError):
        peer_min_protocol = peer_protocol

    local_min = MIN_SUPPORTED_PROTOCOL_VERSION
    local_current = PROTOCOL_VERSION

    compatible = (
        peer_min_protocol <= local_current
        and peer_protocol >= local_min
    )

    if compatible:
        return True, "compatible"

    if peer_protocol < local_min:
        return False, "client is too old"

    if peer_min_protocol > local_current:
        return False, "server is too old"

    return False, "incompatible protocol version"


def version_payload():
    return {
        "server_version": APP_VERSION,
        "protocol_version": PROTOCOL_VERSION,
        "min_protocol_version": MIN_SUPPORTED_PROTOCOL_VERSION,
        "protocol_min_version": MIN_SUPPORTED_PROTOCOL_VERSION,
    }
