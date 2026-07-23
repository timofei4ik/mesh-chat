import json

import websockets

try:
    from server.server_protocol import (
        ACCOUNT_LIVE_FANOUT_PACKET_TYPES,
        version_payload,
    )
except ModuleNotFoundError:
    from server_protocol import (
        ACCOUNT_LIVE_FANOUT_PACKET_TYPES,
        version_payload,
    )


class ServerTransportMixin:
    async def send_server_error(self, websocket, code, message, **details):
        await websocket.send(
            json.dumps(
                {
                    "type": "server_error",
                    "code": code,
                    "message": message,
                    **details,
                },
                ensure_ascii=False,
            )
        )

    def mutation_ack_context(self, node_id, packet):
        capabilities = self.client_capabilities.get(node_id) or {}
        if capabilities.get("mutation_ack") is not True:
            return None

        outbox_id = str(packet.get("outbox_id") or "").strip()
        operation_id = str(packet.get("operation_id") or "").strip()
        if not outbox_id or not operation_id:
            return None

        account_login = str(
            self.client_logins.get(node_id)
            or self.get_login_by_node(node_id)
            or f"@node:{node_id}"
        ).strip().lower()
        if not account_login:
            return None

        return {
            "account_login": account_login,
            "outbox_id": outbox_id,
            "operation_id": operation_id,
        }

    async def send_mutation_ack(
        self,
        websocket,
        packet,
        context,
        ok=True,
        duplicate=False,
        reason="",
    ):
        response = {
            "type": "mutation_ack",
            "ok": bool(ok),
            "duplicate": bool(duplicate),
            "outbox_id": context["outbox_id"],
            "operation_id": context["operation_id"],
            "packet_type": packet.get("type"),
            "packet_id": (
                packet.get("packet_id")
                or packet.get("group_message_id")
                or packet.get("message_id")
                or packet.get("story_id")
                or ""
            ),
            **version_payload(),
        }
        if reason:
            response["reason"] = reason
        await websocket.send(json.dumps(response, ensure_ascii=False))

    async def send_file_transfer_ack(self, websocket, packet, transfer_result):
        response = {
            "type": "file_chunk_ack",
            "ok": transfer_result.get("ok") is True,
            "transfer_id": transfer_result.get("transfer_id") or "",
            "operation_id": packet.get("operation_id") or "",
            "file_id": transfer_result.get("file_id") or "",
            "chunk_index": transfer_result.get("chunk_index"),
            "received_ranges": transfer_result.get("received_ranges") or [],
            "complete": transfer_result.get("complete") is True,
            "retryable": transfer_result.get("retryable") is True,
            "reset": transfer_result.get("reset") is True,
            **version_payload(),
        }
        reason = str(transfer_result.get("reason") or "").strip()
        if reason:
            response["reason"] = reason
        await websocket.send(json.dumps(response, ensure_ascii=False))

    async def deliver_completed_file_transfer(self, transfer_result):
        metadata = transfer_result.get("metadata") or {}
        destination_node = str(metadata.get("destination_node") or "").strip()
        if not destination_node or destination_node.upper() == "SERVER":
            return
        destination_socket = self.clients.get(destination_node)
        if not destination_socket:
            return
        try:
            for delivery_packet in self.iter_file_transfer_delivery_packets(
                transfer_result
            ):
                await destination_socket.send(
                    json.dumps(delivery_packet, ensure_ascii=False)
                )
        except (OSError, websockets.exceptions.ConnectionClosed) as error:
            print(
                "Deferred durable file delivery:",
                transfer_result.get("file_id"),
                destination_node,
                error,
            )

    async def route_packet(self, packet):
        destination_node = packet.get("destination_node")
        if not destination_node:
            return
        if str(destination_node).strip().upper() == "SERVER":
            return

        is_call_packet = str(packet.get("type") or "").startswith("call_")
        if not is_call_packet:
            destination_login = str(
                self.get_login_by_node(destination_node) or ""
            ).strip().lower()
            target_nodes = [str(destination_node)]
            if destination_login:
                target_nodes.extend(self.get_online_account_nodes(destination_login))

            delivered = False
            delivered_nodes = set()
            for target_node in target_nodes:
                if not target_node or target_node in delivered_nodes:
                    continue
                target_socket = self.clients.get(target_node)
                if not target_socket:
                    continue
                routed_packet = packet
                if target_node != destination_node:
                    routed_packet = {
                        **packet,
                        "destination_node": target_node,
                        "original_destination_node": destination_node,
                    }
                routed_packet = self.normalize_group_packet_for_recipient(
                    routed_packet,
                    destination_login,
                    target_node,
                )
                await target_socket.send(
                    json.dumps(routed_packet, ensure_ascii=False)
                )
                delivered_nodes.add(target_node)
                delivered = True

            if delivered:
                return

            self.save_offline_packet(destination_node, packet)
            await self.send_web_push_for_packet(destination_node, packet)
            return

        websocket = self.clients.get(destination_node)
        if websocket:
            await websocket.send(json.dumps(packet, ensure_ascii=False))

        source_node = packet.get("source_node") or ""
        login = self.get_login_by_node(destination_node)
        if login:
            delivered = False
            for node_id in self.get_online_account_nodes(login):
                if node_id == source_node or node_id == destination_node:
                    continue
                websocket = self.clients.get(node_id)
                if not websocket:
                    continue
                await websocket.send(
                    json.dumps(
                        {
                            **packet,
                            "destination_node": node_id,
                            "original_destination_node": destination_node,
                        },
                        ensure_ascii=False,
                    )
                )
                delivered = True
            if delivered:
                return

        await self.send_web_push_for_packet(destination_node, packet)

    async def mirror_packet_to_source_account_devices(self, packet):
        if str(packet.get("type") or "") not in ACCOUNT_LIVE_FANOUT_PACKET_TYPES:
            return

        source_node = str(packet.get("source_node") or "").strip()
        if not source_node:
            return

        source_login = str(
            packet.get("sender_login")
            or self.client_logins.get(source_node)
            or self.get_login_by_node(source_node)
            or ""
        ).strip().lower()
        if not source_login:
            return

        original_destination = packet.get("destination_node")
        for target_node in self.get_online_account_nodes(source_login):
            if not target_node or target_node == source_node:
                continue
            if not self.client_capabilities.get(target_node, {}).get(
                "account_live_fanout", False
            ):
                continue
            target_socket = self.clients.get(target_node)
            if not target_socket:
                continue
            mirrored_packet = self.normalize_group_packet_for_recipient(
                {
                    **packet,
                    "account_mirror": True,
                    "original_destination_node": original_destination,
                },
                source_login,
                target_node,
            )
            await target_socket.send(
                json.dumps(mirrored_packet, ensure_ascii=False)
            )
