import 'dart:ui';

import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import 'profile_avatar.dart';

class InAppMessageBanner extends StatelessWidget {
  const InAppMessageBanner({
    super.key,
    required this.controller,
    required this.onOpen,
    this.top = 12,
  });

  final AppController controller;
  final ValueChanged<ChatThread> onOpen;
  final double top;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final thread = controller.incomingPreviewThread;
        final message = controller.incomingPreviewMessage;
        final visible = thread != null && message != null;
        return Positioned(
          left: 12,
          right: 12,
          top: top,
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedSlide(
              offset: visible ? Offset.zero : const Offset(0, -1.18),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: visible
                    ? _BannerCard(
                        thread: thread,
                        message: message,
                        onTap: () {
                          controller.clearIncomingPreview();
                          onOpen(thread);
                        },
                        onClose: controller.clearIncomingPreview,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({
    required this.thread,
    required this.message,
    required this.onTap,
    required this.onClose,
  });

  final ChatThread thread;
  final ChatMessage message;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final preview = switch (message.kind) {
      ChatMessageKind.sticker => 'Sticker',
      ChatMessageKind.file =>
        message.fileName.toLowerCase().endsWith('.jpg') ||
                message.fileName.toLowerCase().endsWith('.jpeg') ||
                message.fileName.toLowerCase().endsWith('.png') ||
                message.fileName.toLowerCase().endsWith('.webp')
            ? 'Photo'
            : message.fileName.isEmpty
            ? 'File'
            : 'File: ${message.fileName}',
      ChatMessageKind.text => message.text,
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xD4212B35),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            boxShadow: [
              BoxShadow(
                color: Colors.lightBlueAccent.withValues(alpha: 0.12),
                blurRadius: 24,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.24),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                child: Row(
                  children: [
                    ProfileAvatar(profile: thread.profile, radius: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            thread.profile.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white60),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: onClose,
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white60,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
