import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/session.dart';
import 'package:meshchat_mobile/src/models/story_item.dart';
import 'package:meshchat_mobile/src/services/story_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const session = Session(
    serverUrl: 'wss://meshchat-losa.ru/ws',
    serverToken: 'invite',
    login: 'story-user',
    password: 'secret',
    publicUsername: 'story',
    nodeId: 'node-a',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('reload keeps active story views and likes', () async {
    final store = StoryStore();
    final story = StoryItem(
      id: 'story-1',
      ownerNode: 'node-b',
      ownerName: 'Maya',
      createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
      text: 'hello',
      likedByNodeIds: const ['node-a'],
      viewedByNodeIds: const ['node-a', 'node-c'],
    );

    await store.save(session, [story]);
    final loaded = await store.load(session);

    expect(loaded.keys, contains('story-1'));
    expect(loaded['story-1']!.likedByNodeIds, ['node-a']);
    expect(loaded['story-1']!.viewedByNodeIds, ['node-a', 'node-c']);
  });

  test('reload keeps own archive and hidden story owners', () async {
    final store = StoryStore();
    final expiredOwnStory = StoryItem(
      id: 'archive-1',
      ownerNode: 'node-a',
      ownerName: 'Me',
      createdAt: DateTime.now().subtract(const Duration(days: 2)),
      text: 'old story',
    );

    await store.saveArchive(session, [expiredOwnStory]);
    await store.saveHiddenOwners(session, {'node-b', 'node-c'});

    final archive = await store.loadArchive(session);
    final hidden = await store.loadHiddenOwners(session);

    expect(archive.single.id, 'archive-1');
    expect(hidden, {'node-b', 'node-c'});
  });
}
