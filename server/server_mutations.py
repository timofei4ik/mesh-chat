from dataclasses import dataclass
from uuid import uuid4


REACTION_PACKET_TYPES = frozenset(
    {
        "message_reaction",
        "group_reaction",
        "story_reaction",
    }
)


@dataclass(frozen=True)
class MutationPreparation:
    context: dict | None
    duplicate: bool = False


@dataclass(frozen=True)
class MutationOutcome:
    accepted: bool
    duplicate: bool = False
    reason: str = ""


async def prepare_mutation(server, websocket, node_id, packet):
    context = server.mutation_ack_context(node_id, packet)
    if (
        context
        and server.mutation_was_processed(
            context["account_login"],
            context["outbox_id"],
        )
    ):
        await server.send_mutation_ack(
            websocket,
            packet,
            context,
            duplicate=True,
        )
        return MutationPreparation(context=context, duplicate=True)

    return MutationPreparation(context=context)


def enrich_mutation_identity(server, node_id, packet):
    source_login = str(
        server.client_logins.get(node_id)
        or server.get_login_by_node(node_id)
        or ""
    ).strip().lower()
    destination_login = str(
        server.get_login_by_node(packet.get("destination_node"))
        or ""
    ).strip().lower()

    if source_login:
        packet["sender_login"] = source_login
        if packet.get("type") in REACTION_PACKET_TYPES:
            packet["reactor_login"] = source_login
            packet["reactor_identity"] = f"login:{source_login}"
    if destination_login:
        packet["receiver_login"] = destination_login


async def execute_history_mutation(
    server,
    websocket,
    node_id,
    packet,
    mutation_context,
):
    if not server.authorize_group_management(packet):
        print(
            "Rejected unauthorized group management:",
            packet.get("type"),
            packet.get("group_id"),
            node_id,
        )
        if mutation_context:
            await server.send_mutation_ack(
                websocket,
                packet,
                mutation_context,
                ok=False,
                reason="unauthorized_group_management",
            )
        return MutationOutcome(
            accepted=False,
            reason="unauthorized_group_management",
        )

    group_delete_targets = (
        server.get_group_delivery_nodes(packet.get("group_id"))
        if packet.get("type") == "group_delete"
        else []
    )

    enrich_mutation_identity(server, node_id, packet)
    sync_event_accounts = server.sync_v2_accounts_for_packet(
        packet,
        group_delete_targets,
    )
    mutation_result = server.persist_history_mutation(
        packet,
        sync_event_accounts,
        mutation_context,
    )
    saved = mutation_result["saved"]

    if saved == "duplicate":
        if mutation_context:
            await server.send_mutation_ack(
                websocket,
                packet,
                mutation_context,
                duplicate=True,
            )
        return MutationOutcome(accepted=False, duplicate=True)

    if saved is False:
        if mutation_context:
            await server.send_mutation_ack(
                websocket,
                packet,
                mutation_context,
                ok=False,
                reason="rejected",
            )
        return MutationOutcome(accepted=False, reason="rejected")

    if mutation_context:
        inserted = mutation_result["processed_inserted"]
        await server.send_mutation_ack(
            websocket,
            packet,
            mutation_context,
            duplicate=not inserted,
        )

    await server.mirror_packet_to_source_account_devices(packet)

    if packet.get("type") == "group_delete":
        source_node = packet.get("source_node") or ""
        for target_node in group_delete_targets:
            if not target_node or target_node == source_node:
                continue
            await server.route_packet(
                {
                    **packet,
                    "packet_id": str(uuid4()),
                    "destination_node": target_node,
                }
            )
        return MutationOutcome(accepted=True)

    await server.route_packet(packet)
    return MutationOutcome(accepted=True)
