import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/models/chat_thread.dart';
import 'package:meshchat_mobile/src/models/profile.dart';

class _VisibilityController extends AppController {
  final reads = <ChatThread>[];
  @override
  void markRead(ChatThread thread) => reads.add(thread);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'hidden window does not read chats; returning reads only the visible chat',
    () async {
      final controller = _VisibilityController();
      final first = ChatThread(
        profile: const Profile(nodeId: 'first', displayName: 'First'),
      );
      final second = ChatThread(
        profile: const Profile(nodeId: 'second', displayName: 'Second'),
      );
      controller.threads[first.storageKey] = first;
      controller.threads[second.storageKey] = second;
      controller.setActiveThread(first);
      expect(controller.reads, [first]);
      await controller.handleAppPaused();
      expect(controller.appForeground, isFalse);
      controller.setActiveThread(second);
      expect(controller.reads, [first]);
      controller.setAppForeground(true);
      expect(controller.reads, [first, second]);
      controller.setAppForeground(true);
      expect(controller.reads, [first, second]);
    },
  );

  test(
    'disposing a chat while hidden does not leave it active on return',
    () async {
      final controller = _VisibilityController();
      final thread = ChatThread(
        profile: const Profile(nodeId: 'peer', displayName: 'Peer'),
      );
      controller.threads[thread.storageKey] = thread;
      controller.setActiveThread(thread);
      await controller.handleAppPaused();
      controller.clearActiveThread(thread);
      controller.setAppForeground(true);
      expect(controller.reads, [thread]);
    },
  );
}
