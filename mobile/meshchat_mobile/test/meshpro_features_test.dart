import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';
import 'package:meshchat_mobile/src/models/scheduled_message.dart';
import 'package:meshchat_mobile/src/models/story_item.dart';

void main() {
  test('chat appearance round-trips and legacy cache uses safe defaults', () {
    final styled = ChatThread.fromJson({
      'profile': {'node_id': 'friend', 'display_name': 'Friend'},
      'theme_id': 'violet',
      'bubble_style': 'compact',
      'animated_background': false,
    });
    final legacy = ChatThread.fromJson({
      'profile': {'node_id': 'legacy', 'display_name': 'Legacy'},
    });
    final invalid = ChatThread.fromJson({
      'profile': {'node_id': 'invalid', 'display_name': 'Invalid'},
      'theme_id': 'rainbow',
      'bubble_style': 'giant',
    });

    expect(styled.themeId, 'violet');
    expect(styled.bubbleStyle, 'compact');
    expect(styled.animatedBackground, isFalse);
    expect(styled.toJson()['theme_id'], 'violet');
    expect(legacy.themeId, 'midnight');
    expect(legacy.bubbleStyle, 'classic');
    expect(legacy.animatedBackground, isFalse);
    expect(invalid.themeId, 'midnight');
    expect(invalid.bubbleStyle, 'classic');
  });

  test('scheduled message parses server fields and repeat state', () {
    final item = ScheduledMessageItem.fromJson({
      'schedule_id': 'schedule-1',
      'chat_key': 'direct:friend',
      'preview': 'Tomorrow morning',
      'next_run_at': '2099-07-15T08:30:00Z',
      'repeat_interval': 'daily',
      'run_count': 2,
    });

    expect(item.id, 'schedule-1');
    expect(item.chatKey, 'direct:friend');
    expect(item.preview, 'Tomorrow morning');
    expect(item.repeats, isTrue);
    expect(item.runCount, 2);
  });

  test('HD story and reaction map survive cache round-trip', () {
    final original = StoryItem(
      id: 'story-1',
      ownerNode: 'owner',
      ownerName: 'Owner',
      createdAt: DateTime.utc(2099, 7, 15),
      mediaType: StoryMediaType.video,
      videoData: 'encoded-video',
      hd: true,
      videoDurationSeconds: 90,
      reactions: const {
        'heart': ['viewer-a'],
        'fire': ['viewer-b'],
      },
      likedByNodeIds: const ['viewer-a'],
    );
    final restored = StoryItem.fromJson(original.toJson());

    expect(restored.hd, isTrue);
    expect(restored.videoDurationSeconds, 90);
    expect(restored.reactionCount, 2);
    expect(restored.reactionFor('viewer-b'), 'fire');
    expect(restored.likedByNodeIds, ['viewer-a']);
  });

  test('new reaction payload keeps legacy heart compatibility', () {
    final restored = StoryItem.fromJson({
      'id': 'story-2',
      'owner_node': 'owner',
      'owner_name': 'Owner',
      'created_at': '2099-07-15T08:30:00Z',
      'reactions': {
        'heart': ['viewer-a'],
        'clap': ['viewer-b'],
      },
    });

    expect(restored.likedByNodeIds, ['viewer-a']);
    expect(restored.reactionCount, 2);
  });

  test('animated avatar data and emoji status remain in profile cache', () {
    final profile = Profile.fromJson({
      'node_id': 'subscriber',
      'display_name': 'Subscriber',
      'avatar_data': 'data:image/gif;base64,R0lGODlh',
      'emoji_status': '💎',
    });

    expect(profile.avatarData, startsWith('data:image/gif'));
    expect(profile.emojiStatus, '💎');
    expect(profile.toJson()['emoji_status'], '💎');
  });
}
