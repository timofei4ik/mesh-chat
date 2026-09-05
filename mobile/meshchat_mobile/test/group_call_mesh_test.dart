import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/group_call_mesh.dart';
import 'package:meshchat_mobile/src/services/shared_call_resource.dart';

void main() {
  test('eight participants produce exactly one offer per pair', () {
    final members = List.generate(8, (index) => 'node-$index');
    const host = 'node-4';
    final pairs = <String, int>{};
    void offer(String a, String b) {
      final sorted = [a, b]..sort();
      pairs.update(sorted.join(':'), (value) => value + 1, ifAbsent: () => 1);
    }

    for (final node in members) {
      final mesh = GroupCallMesh(
        localNode: node,
        hostNode: host,
        members: members,
      )..accepted = true;
      for (final peer in members) {
        mesh.markReady(peer);
        if (node == host && peer != host || mesh.shouldOffer(peer)) {
          offer(node, peer);
        }
      }
    }
    expect(pairs.length, 28);
    expect(pairs.values, everyElement(1));
  });

  test('ringing devices never open guest links before accepting', () {
    final mesh = GroupCallMesh(
      localNode: 'a',
      hostNode: 'host',
      members: ['a', 'b'],
    );
    mesh.markReady('b');
    expect(mesh.shouldOffer('b'), isFalse);
    expect(mesh.acceptsOffer('b'), isFalse);
    mesh.accepted = true;
    expect(mesh.shouldOffer('b'), isTrue);
    expect(mesh.shouldOffer('outsider'), isFalse);
  });

  test('offer direction and ICE restart owner are deterministic', () {
    final a = GroupCallMesh(
      localNode: 'a',
      hostNode: 'host',
      members: ['a', 'b'],
    )..accepted = true;
    final b = GroupCallMesh(
      localNode: 'b',
      hostNode: 'host',
      members: ['a', 'b'],
    )..accepted = true;
    a.markReady('b');
    b.markReady('a');
    expect(a.shouldOffer('b'), isTrue);
    expect(b.acceptsOffer('a'), isTrue);
    expect(a.acceptsOffer('b'), isFalse);
    expect(b.shouldOffer('a'), isFalse);
    expect(a.shouldRestart('b'), isTrue);
    expect(b.shouldRestart('a'), isFalse);
    expect(a.shouldRestart('host'), isFalse);
  });

  test(
    'host departure leaves guest links, late ready cannot resurrect a peer',
    () {
      final mesh = GroupCallMesh(
        localNode: 'a',
        hostNode: 'host',
        members: ['a', 'b'],
      )..accepted = true;
      mesh.markReady('host');
      mesh.markReady('b');
      mesh.leave('host');
      expect(mesh.shouldOffer('b'), isTrue);
      mesh.leave('b');
      expect(mesh.markReady('b'), isFalse);
      expect(mesh.shouldOffer('b'), isFalse);
      expect(mesh.markReady('outsider'), isFalse);
    },
  );

  test(
    'concurrent peer links share one microphone until the last lease closes',
    () async {
      final pool = SharedCallResource<Object>();
      final pending = Completer<Object>();
      var opened = 0;
      var closed = 0;
      Future<Object> open() {
        opened++;
        return pending.future;
      }

      Future<void> close(Object value) async {
        closed++;
      }

      final first = pool.acquire('room', open, close);
      final second = pool.acquire('room', open, close);
      pending.complete(Object());
      final a = await first;
      final b = await second;
      expect(opened, 1);
      expect(identical(a.value, b.value), isTrue);
      await a.close();
      await a.close();
      expect(closed, 0);
      await b.close();
      expect(closed, 1);
      final c = await pool.acquire('room', open, close);
      expect(opened, 2);
      await c.close();
    },
  );

  test(
    'microphone failures are recoverable and rooms do not share capture',
    () async {
      final pool = SharedCallResource<Object>();
      Future<void> close(Object _) async {}
      await expectLater(
        pool.acquire('room', () => throw StateError('permission'), close),
        throwsStateError,
      );
      final a = await pool.acquire('room', () async => Object(), close);
      final b = await pool.acquire('another', () async => Object(), close);
      expect(identical(a.value, b.value), isFalse);
      await a.close();
      await b.close();
    },
  );
}
