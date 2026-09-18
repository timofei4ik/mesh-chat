import unittest
from types import SimpleNamespace
from server.server_command_bus import ConnectionContext
from server.server_commands_sync import handle_file_chunk_v2
from server.server_transport import ServerTransportMixin


class Relay(ServerTransportMixin):
    def __init__(self):
        self.logins = {'phone': 'alice', 'desktop': 'alice', 'peer': 'bob', 'tablet': 'bob'}
        self.sent = []
        self.legacy = set()
        self.broken = set()

    def get_login_by_node(self, node):
        return self.logins.get(node, '')

    def get_online_account_nodes(self, login):
        return [node for node, owner in self.logins.items() if owner == login]

    def normalize_group_packet_for_recipient(self, packet, login, node):
        return {**packet, 'normalized_for': node}

    async def _send_live_packet(self, node, packet, required_capability=None):
        if node in self.broken:
            raise OSError('device disconnected')
        if required_capability and node in self.legacy:
            return False
        self.sent.append((node, packet))
        return True

    def iter_file_transfer_delivery_packets(self, result):
        yield {**result['metadata'], 'type': 'file_chunk', 'file_id': result['file_id'], 'chunk_index': 0}


class FileAccountFanoutTests(unittest.IsolatedAsyncioTestCase):
    async def test_offline_sync_is_invalidated_before_ack_including_completed_retry(self):
        for new in (True, False):
            events = []
            async def ack(*args):
                events.append('ack')
            async def deliver(*args):
                events.append('deliver')
            relay = SimpleNamespace(
                client_capabilities={'phone': {'file_transfer_v2': True}},
                client_logins={'phone': 'alice'},
                save_file_transfer_chunk=lambda packet, login: {'ok': True, 'complete': True, 'newly_completed': new, 'file_id': 'photo'},
                sync_v2_accounts_for_packet=lambda packet, targets: ['alice', 'bob'],
                invalidate_sync_v2_snapshot=lambda login, reason, operation, metadata: events.append((login, operation)),
                send_file_transfer_ack=ack,
                deliver_completed_file_transfer=deliver,
            )
            await handle_file_chunk_v2(relay, {'file_transfer_v2': True, 'file_id': 'photo'}, ConnectionContext(None, 'phone'))
            self.assertEqual([('alice', 'file-complete:photo'), ('bob', 'file-complete:photo'), 'ack'], events[:3])
            self.assertEqual(new, 'deliver' in events)

    def result(self):
        return {'metadata': {'source_node': 'phone', 'destination_node': 'peer'}, 'file_id': 'photo', 'sha256': 'hash', 'size_bytes': 12}

    async def test_completed_upload_reaches_both_accounts_other_devices(self):
        relay = Relay()
        await relay.deliver_completed_file_transfer(self.result())
        self.assertEqual({'peer', 'desktop', 'tablet'}, {node for node, _ in relay.sent})
        self.assertEqual(3, len(relay.sent))
        for node, packet in relay.sent:
            self.assertEqual('file_manifest', packet['type'])
            self.assertEqual('alice', packet['sender_login'])
            self.assertEqual('bob', packet['receiver_login'])
            self.assertEqual('peer', packet['destination_node'])
            self.assertEqual(node, packet['normalized_for'])

    async def test_one_disconnected_device_does_not_block_others_or_legacy(self):
        relay = Relay()
        relay.broken.add('peer')
        relay.legacy.add('desktop')
        await relay.deliver_completed_file_transfer(self.result())
        packets = dict(relay.sent)
        self.assertEqual({'desktop', 'tablet'}, set(packets))
        self.assertEqual('file_chunk', packets['desktop']['type'])
        self.assertEqual('alice', packets['desktop']['sender_login'])

    async def test_self_account_has_no_duplicate_delivery(self):
        relay = Relay()
        result = self.result()
        result['metadata']['destination_node'] = 'desktop'
        await relay.deliver_completed_file_transfer(result)
        self.assertEqual(['desktop'], [node for node, _ in relay.sent])
