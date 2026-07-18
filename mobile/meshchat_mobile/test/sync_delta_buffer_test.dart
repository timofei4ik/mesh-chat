import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/sync_delta_buffer.dart';

Map<String, dynamic> beginPacket({
  String syncId = 'sync-a',
  int source = 10,
  int target = 12,
  int count = 2,
  int floor = 0,
}) => {
  'type': 'server_sync_delta_begin',
  'version': 2,
  'sync_id': syncId,
  'source_cursor': source,
  'target_cursor': target,
  'retained_floor': floor,
  'event_count': count,
};

Map<String, dynamic> eventPacket(
  int eventId,
  String messageId, {
  String syncId = 'sync-a',
}) => {
  'type': 'server_sync_delta_event',
  'sync_id': syncId,
  'event': {
    'event_id': eventId,
    'operation_id': 'chat_message:$messageId',
    'packet_type': 'chat_message',
    'requires_snapshot': false,
    'payload': {
      'type': 'chat_message',
      'packet_id': messageId,
      'message': 'ciphertext:$messageId',
    },
  },
};

Map<String, dynamic> donePacket({
  String syncId = 'sync-a',
  int source = 10,
  int target = 12,
  int count = 2,
}) => {
  'type': 'server_sync_done',
  'sync_cursor': target,
  'sync_v2': {
    'version': 2,
    'mode': 'delta',
    'sync_id': syncId,
    'source_cursor': source,
    'cursor': target,
    'event_count': count,
  },
};

void main() {
  test('buffers a complete ordered delta before exposing the batch', () {
    final buffer = SyncDeltaBuffer();
    buffer.begin(beginPacket(), localCursor: 10);
    buffer.addEvent(eventPacket(11, 'message-b'));
    buffer.addEvent(eventPacket(12, 'message-c'));
    buffer.bufferLivePacket({
      'type': 'message_delete',
      'message_id': 'message-live',
    });

    final batch = buffer.complete(donePacket());

    expect(batch.sourceCursor, 10);
    expect(batch.targetCursor, 12);
    expect(batch.events.map((event) => event['packet_id']), [
      'message-b',
      'message-c',
    ]);
    expect(batch.livePackets.single['message_id'], 'message-live');
    expect(buffer.isActive, isFalse);
  });

  test('an interrupted delta can be aborted and replayed from old cursor', () {
    final buffer = SyncDeltaBuffer();
    buffer.begin(beginPacket(), localCursor: 10);
    buffer.addEvent(eventPacket(11, 'message-b'));
    buffer.abort();

    buffer.begin(beginPacket(), localCursor: 10);
    buffer.addEvent(eventPacket(11, 'message-b'));
    buffer.addEvent(eventPacket(12, 'message-c'));

    expect(buffer.complete(donePacket()).targetCursor, 12);
  });

  test('rejects changed ids, out-of-order events, and incomplete ranges', () {
    final changedId = SyncDeltaBuffer();
    changedId.begin(beginPacket(), localCursor: 10);
    expect(
      () => changedId.addEvent(
        eventPacket(11, 'message-b', syncId: 'sync-other'),
      ),
      throwsFormatException,
    );

    final outOfOrder = SyncDeltaBuffer();
    outOfOrder.begin(beginPacket(), localCursor: 10);
    outOfOrder.addEvent(eventPacket(12, 'message-c'));
    expect(
      () => outOfOrder.addEvent(eventPacket(11, 'message-b')),
      throwsFormatException,
    );

    final incomplete = SyncDeltaBuffer();
    incomplete.begin(beginPacket(), localCursor: 10);
    incomplete.addEvent(eventPacket(11, 'message-b'));
    expect(() => incomplete.complete(donePacket()), throwsFormatException);
  });

  test('rejects pruned source cursors and snapshot-only events', () {
    final pruned = SyncDeltaBuffer();
    expect(
      () => pruned.begin(beginPacket(floor: 11), localCursor: 10),
      throwsFormatException,
    );

    final unsafe = SyncDeltaBuffer();
    unsafe.begin(beginPacket(count: 1, target: 11), localCursor: 10);
    final packet = eventPacket(11, 'message-b');
    (packet['event'] as Map<String, dynamic>)['requires_snapshot'] = true;
    expect(() => unsafe.addEvent(packet), throwsFormatException);
  });
}
