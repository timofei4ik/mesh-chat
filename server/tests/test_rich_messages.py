import asyncio
import json
import unittest

from server.tests import test_sync_v2_contract as contract
from server.server_ai_tools import normalize_tool_request


class RichMessagesTests(unittest.TestCase):
    setUp = contract.SyncV2ContractTests.setUp
    tearDown = contract.SyncV2ContractTests.tearDown
    register_device = contract.SyncV2ContractTests.register_device

    def setup_accounts(self):
        self.register_device('alice', 'alice-phone')
        self.register_device('bob', 'bob-phone')

    def persist(self, packet):
        return self.relay.persist_history_mutation(packet, ['alice', 'bob'])['saved']

    def snapshot(self):
        socket = contract.CapturingWebSocket()
        asyncio.run(self.relay.send_account_sync(socket, 'bob', 'bob-phone', supports_sync_v2=True))
        return json.dumps(socket.sent)

    def test_direct_round_trip_duplicate_edit_and_old_client_edit(self):
        self.setup_accounts()
        packet = {'type': 'chat_message', 'packet_id': 'rich-one', 'operation_id': 'chat:rich-one',
                  'source_node': 'alice-phone', 'destination_node': 'bob-phone',
                  'message': 'MCENC1:plain-fallback', 'rich_content': 'MCENC1:rich-first'}
        self.assertIsNot(self.persist(packet), False)
        self.persist(packet)
        self.assertEqual(1, self.relay.db.execute('SELECT COUNT(*) FROM direct_messages').fetchone()[0])
        self.assertIn('MCENC1:rich-first', self.snapshot())
        cursor = self.relay.sync_v2_cursor('bob')
        edit = {**packet, 'type': 'message_edit', 'message_id': 'rich-one',
                'packet_id': 'edit-one', 'operation_id': 'edit:one',
                'message': 'MCENC1:updated-fallback', 'rich_content': 'MCENC1:rich-updated'}
        self.assertIsNot(self.persist(edit), False)
        snapshot = self.snapshot()
        self.assertIn('MCENC1:rich-updated', snapshot)
        self.assertNotIn('MCENC1:rich-first', snapshot)
        plan = self.relay.plan_sync_v2_delivery('bob', cursor, supports_delta=True)
        self.assertIn('MCENC1:rich-updated', json.dumps(plan))
        edit.pop('rich_content')
        edit.update(operation_id='edit:legacy', packet_id='edit-legacy')
        self.assertIsNot(self.persist(edit), False)
        self.assertEqual('', self.relay.db.execute('SELECT rich_content FROM direct_messages').fetchone()[0])
        self.assertNotIn('MCENC1:rich-updated', self.snapshot())

    def test_group_round_trip_and_edit(self):
        self.setup_accounts()
        self.relay.save_history_packet({'type': 'group_update', 'packet_id': 'group-one',
          'group_id': 'group-one', 'group_name': 'Group', 'owner_node': 'alice-phone',
          'source_node': 'alice-phone', 'members': ['alice-phone', 'bob-phone'], 'admins': []})
        packet = {'type': 'group_message', 'packet_id': 'group-rich-one',
          'group_message_id': 'group-rich-one', 'operation_id': 'group_message:rich-one',
          'group_id': 'group-one', 'source_node': 'alice-phone', 'destination_node': 'bob-phone',
          'group_name': 'Group', 'owner_node': 'alice-phone', 'members': ['alice-phone', 'bob-phone'],
          'message': 'MCGRP1:plain', 'rich_content': 'MCGRP1:rich', 'group_key_id': 'key-one'}
        self.assertIsNot(self.persist(packet), False)
        self.assertIn('MCGRP1:rich', self.snapshot())
        packet.update(type='group_message_edit', packet_id='group-edit', operation_id='group_edit:one',
                      message='MCGRP1:plain-new', rich_content='MCGRP1:rich-new')
        packet.pop('members')
        packet.pop('owner_node')
        self.assertIsNot(self.persist(packet), False)
        self.assertEqual('MCGRP1:rich-new', self.relay.db.execute('SELECT rich_content FROM server_group_messages').fetchone()[0])
        self.assertIn('MCGRP1:rich-new', self.snapshot())

    def test_rejects_plaintext_oversized_and_wrong_encryption_family(self):
        self.setup_accounts()
        for index, value in enumerate(['{"v":1}', 'MCGRP1:wrong-family', 'MCENC1:' + 'x' * (768 * 1024), []]):
            packet = {'type': 'chat_message', 'packet_id': f'invalid-{index}',
              'source_node': 'alice-phone', 'destination_node': 'bob-phone',
              'message': 'MCENC1:plain', 'rich_content': value}
            self.assertIs(self.relay.save_history_packet(packet), False)
        self.assertEqual(0, self.relay.db.execute('SELECT COUNT(*) FROM direct_messages').fetchone()[0])

    def test_compose_accepts_only_explicit_instruction_without_history(self):
        request = normalize_tool_request({'mode': 'compose', 'instruction': 'Write a short greeting'})
        self.assertEqual([], request['sources'])
        with self.assertRaises(ValueError):
            normalize_tool_request({'mode': 'compose'})
