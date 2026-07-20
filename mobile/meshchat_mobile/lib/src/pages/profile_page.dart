import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../models/profile.dart';
import '../widgets/meshpro_badge.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/profile_effect_background.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    required this.profile,
    this.controller,
    this.thread,
    this.onMessage,
    this.onCall,
    this.onMedia,
  });

  final Profile profile;
  final AppController? controller;
  final ChatThread? thread;
  final VoidCallback? onMessage;
  final VoidCallback? onCall;
  final VoidCallback? onMedia;

  @override
  Widget build(BuildContext context) {
    final username = profile.publicUsername.isEmpty
        ? ''
        : '@${profile.publicUsername}';
    final isSavedMessages =
        profile.nodeId.startsWith('saved:') ||
        profile.publicUsername == 'saved';
    final currentThread = thread;
    final currentController = controller;
    final blocked =
        currentController != null &&
        currentController.isBlocked(profile.nodeId);
    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      body: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xFF07111E)),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 34),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: _ProfileRoundButton(
                  tooltip: 'Back',
                  icon: Icons.arrow_back_ios_new_rounded,
                  onTap: () => Navigator.maybePop(context),
                ),
              ),
              const SizedBox(height: 4),
              _ProfileHero(
                profile: profile,
                username: username,
                showOnline: !isSavedMessages,
              ),
              const SizedBox(height: 18),
              _ProfileActions(
                muted: currentThread?.muted ?? false,
                blocked: blocked,
                onMessage: onMessage,
                onCall: isSavedMessages ? null : onCall,
                onMute: currentThread == null || currentController == null
                    ? null
                    : () => currentController.toggleThreadMute(currentThread),
              ),
              const SizedBox(height: 18),
              if (profile.about.trim().isNotEmpty)
                _ProfileInfoTile(
                  icon: Icons.info_outline_rounded,
                  title: 'About',
                  value: profile.about.trim(),
                ),
              _ProfileInfoTile(
                icon: profile.publicKey.isEmpty
                    ? Icons.lock_open_rounded
                    : Icons.lock_rounded,
                title: 'Encryption',
                value: profile.publicKey.isEmpty
                    ? 'Encryption key is not available yet'
                    : 'End-to-end encryption key is available',
              ),
              _ProfileInfoTile(
                icon: Icons.fingerprint_rounded,
                title: 'Node ID',
                value: profile.nodeId,
                copyable: true,
              ),
              const SizedBox(height: 8),
              _ProfileMediaBrowser(thread: currentThread, onOpenAll: onMedia),
              const SizedBox(height: 12),
              if (currentController != null && currentThread != null)
                _ProfileDangerActions(
                  blocked: blocked,
                  onBlock: () =>
                      currentController.toggleBlocked(profile.nodeId),
                  onDeleteLocal: () => _confirmDeleteChat(
                    context,
                    currentController,
                    currentThread,
                    forEveryone: false,
                  ),
                  onDeleteBoth: () => _confirmDeleteChat(
                    context,
                    currentController,
                    currentThread,
                    forEveryone: true,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteChat(
    BuildContext context,
    AppController controller,
    ChatThread thread, {
    required bool forEveryone,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(forEveryone ? 'Delete for everyone?' : 'Delete chat?'),
        content: Text(
          forEveryone
              ? 'This will remove the chat from the server and from other participants where possible.'
              : 'This will remove the chat only on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    if (forEveryone) {
      await controller.deleteThreadForEveryone(thread);
    } else {
      await controller.deleteThread(thread);
    }
    if (!context.mounted) return;
    final navigator = Navigator.of(context);
    navigator.pop();
    if (navigator.canPop()) navigator.pop();
  }
}

class _ProfileHero extends StatefulWidget {
  const _ProfileHero({
    required this.profile,
    required this.username,
    required this.showOnline,
  });

  final Profile profile;
  final String username;
  final bool showOnline;

  @override
  State<_ProfileHero> createState() => _ProfileHeroState();
}

class _ProfileHeroState extends State<_ProfileHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController expansion;
  bool hapticThresholdReached = false;
  bool closingAfterCollapse = false;

  bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  void initState() {
    super.initState();
    expansion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      reverseDuration: const Duration(milliseconds: 330),
    );
  }

  void updateExpansion(double delta) {
    final previous = expansion.value;
    expansion.value = (expansion.value - delta / 230).clamp(0.0, 1.0);
    final crossed = previous < 0.56 && expansion.value >= 0.56;
    if (crossed && !hapticThresholdReached) {
      hapticThresholdReached = true;
      unawaited(HapticFeedback.selectionClick());
    } else if (expansion.value < 0.42) {
      hapticThresholdReached = false;
    }
  }

  Future<void> settleExpansion([bool? expand]) async {
    final shouldExpand = expand ?? expansion.value >= 0.48;
    if (shouldExpand) {
      if (!hapticThresholdReached) {
        hapticThresholdReached = true;
        await HapticFeedback.selectionClick();
      }
      await expansion.animateTo(1, curve: Curves.easeOutCubic);
    } else {
      hapticThresholdReached = false;
      await expansion.animateBack(0, curve: Curves.easeOutCubic);
    }
  }

  Future<void> handleRoutePop(bool didPop) async {
    if (didPop || closingAfterCollapse || expansion.value < 0.04) return;
    closingAfterCollapse = true;
    await settleExpansion(false);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    expansion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final username = widget.username;
    final hasAvatarDecoration =
        profile.effectiveAvatarDecoration != Profile.defaultAvatarDecoration;
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedBuilder(
        animation: expansion,
        builder: (context, _) {
          final value = Curves.easeInOutCubic.transform(expansion.value);
          final expandedSide = (constraints.maxWidth - 8).clamp(220.0, 520.0);
          final avatarRadius = lerpDouble(76, expandedSide / 2, value)!;
          final height = lerpDouble(276, expandedSide + 20, value)!;
          final labelOpacity = (1 - value * 1.5).clamp(0.0, 1.0);
          return PopScope<void>(
            canPop: expansion.value < 0.04,
            onPopInvokedWithResult: (didPop, _) => handleRoutePop(didPop),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => settleExpansion(expansion.value < 0.5),
              onVerticalDragUpdate: isDesktop
                  ? null
                  : (details) => updateExpansion(details.delta.dy),
              onVerticalDragEnd: isDesktop ? null : (_) => settleExpansion(),
              child: SizedBox(
                height: height,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    lerpDouble(28, 18, value)!,
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: ProfileEffectBackground(
                          profile: profile,
                          enabled: profile.meshProBadge == true,
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: lerpDouble(72, 34, value),
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  const Color(0xFF07111E),
                                  const Color(0xFF07111E).withValues(alpha: 0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment(0, lerpDouble(-0.42, 0, value)!),
                        child: Container(
                          padding: EdgeInsets.all(
                            hasAvatarDecoration ? 0 : lerpDouble(6, 0, value)!,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              lerpDouble(avatarRadius, 18, value)!,
                            ),
                            border: hasAvatarDecoration || value > 0.92
                                ? null
                                : Border.all(
                                    color: Color(
                                      profile.effectiveProfileAccent,
                                    ).withValues(alpha: 0.58 * (1 - value)),
                                  ),
                            boxShadow: [
                              BoxShadow(
                                color: Color(profile.effectiveProfileAccent)
                                    .withValues(
                                      alpha:
                                          (profile.effectiveProfileGlow
                                              ? 0.42
                                              : 0.18) *
                                          (1 - value * 0.7),
                                    ),
                                blurRadius: profile.effectiveProfileGlow
                                    ? 46
                                    : 28,
                                spreadRadius: profile.effectiveProfileGlow
                                    ? 4
                                    : 1,
                              ),
                            ],
                          ),
                          child: ProfileAvatar(
                            profile: profile,
                            radius: avatarRadius,
                            squareProgress: value,
                            animateDecoration: value < 0.9,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 22,
                        child: IgnorePointer(
                          child: Opacity(
                            opacity: labelOpacity,
                            child: Column(
                              children: [
                                MeshProProfileName(
                                  profile: profile,
                                  animate: true,
                                  badgeSize: 22,
                                  style: const TextStyle(
                                    fontSize: 25,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                if (username.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    username,
                                    style: const TextStyle(
                                      color: Colors.white60,
                                    ),
                                  ),
                                ],
                                if (widget.showOnline) ...[
                                  const SizedBox(height: 8),
                                  _OnlinePill(online: profile.online),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (!isDesktop)
                        Positioned(
                          top: 10,
                          child: Opacity(
                            opacity: (1 - value).clamp(0.0, 1.0),
                            child: Container(
                              width: 38,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ProfileActions extends StatelessWidget {
  const _ProfileActions({
    required this.muted,
    required this.blocked,
    required this.onMessage,
    required this.onCall,
    required this.onMute,
  });

  final bool muted;
  final bool blocked;
  final VoidCallback? onMessage;
  final VoidCallback? onCall;
  final VoidCallback? onMute;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ProfileActionButton(
          icon: Icons.chat_bubble_outline_rounded,
          label: 'Message',
          onTap: onMessage,
        ),
        if (onCall != null)
          _ProfileActionButton(
            icon: Icons.call_outlined,
            label: 'Call',
            onTap: onCall,
          ),
        _ProfileActionButton(
          icon: muted || blocked
              ? Icons.notifications_off_outlined
              : Icons.notifications_active_outlined,
          label: muted ? 'Muted' : 'Mute',
          onTap: onMute,
        ),
      ],
    );
  }
}

class _ProfileActionButton extends StatelessWidget {
  const _ProfileActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ProfileRoundButton(tooltip: label, icon: icon, onTap: onTap),
        const SizedBox(height: 7),
        Text(
          label,
          style: TextStyle(
            color: onTap == null ? Colors.white30 : Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _ProfileRoundButton extends StatelessWidget {
  const _ProfileRoundButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        clipBehavior: Clip.antiAlias,
        shape: const CircleBorder(),
        color: Colors.white.withValues(alpha: onTap == null ? 0.06 : 0.11),
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              boxShadow: [
                BoxShadow(
                  color: Colors.lightBlueAccent.withValues(
                    alpha: onTap == null ? 0 : 0.14,
                  ),
                  blurRadius: 18,
                ),
              ],
            ),
            child: Icon(
              icon,
              color: onTap == null ? Colors.white30 : Colors.lightBlueAccent,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}

class _OnlinePill extends StatelessWidget {
  const _OnlinePill({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online ? Colors.greenAccent : Colors.white54;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: online ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: 7),
            Text(
              online ? 'online' : 'offline',
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileInfoTile extends StatelessWidget {
  const _ProfileInfoTile({
    required this.icon,
    required this.title,
    required this.value,
    this.copyable = false,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _ProfileGlassSurface(
        radius: 22,
        child: InkWell(
          onTap: copyable
              ? () {
                  Clipboard.setData(ClipboardData(text: value));
                }
              : null,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  color: Colors.lightBlueAccent.withValues(alpha: 0.86),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(color: Colors.white54),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(value),
                    ],
                  ),
                ),
                if (copyable)
                  const Icon(
                    Icons.copy_rounded,
                    size: 18,
                    color: Colors.white38,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _ProfileMediaTab { media, files, voice, links }

class _ProfileMediaBrowser extends StatefulWidget {
  const _ProfileMediaBrowser({required this.thread, required this.onOpenAll});

  final ChatThread? thread;
  final VoidCallback? onOpenAll;

  @override
  State<_ProfileMediaBrowser> createState() => _ProfileMediaBrowserState();
}

class _ProfileMediaBrowserState extends State<_ProfileMediaBrowser> {
  _ProfileMediaTab selected = _ProfileMediaTab.media;

  @override
  Widget build(BuildContext context) {
    final buckets = _ProfileMediaBuckets.fromThread(widget.thread);
    final items = buckets.itemsFor(selected);

    return _ProfileGlassSurface(
      radius: 24,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Row(
              children: [
                _MediaFilterChip(
                  icon: Icons.photo_library_outlined,
                  label: 'Media',
                  count: buckets.media.length,
                  selected: selected == _ProfileMediaTab.media,
                  onTap: () =>
                      setState(() => selected = _ProfileMediaTab.media),
                ),
                _MediaFilterChip(
                  icon: Icons.insert_drive_file_outlined,
                  label: 'Files',
                  count: buckets.files.length,
                  selected: selected == _ProfileMediaTab.files,
                  onTap: () =>
                      setState(() => selected = _ProfileMediaTab.files),
                ),
                _MediaFilterChip(
                  icon: Icons.keyboard_voice_outlined,
                  label: 'Voice',
                  count: buckets.voice.length,
                  selected: selected == _ProfileMediaTab.voice,
                  onTap: () =>
                      setState(() => selected = _ProfileMediaTab.voice),
                ),
                _MediaFilterChip(
                  icon: Icons.link_rounded,
                  label: 'Links',
                  count: buckets.links.length,
                  selected: selected == _ProfileMediaTab.links,
                  onTap: () =>
                      setState(() => selected = _ProfileMediaTab.links),
                ),
              ],
            ),
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: items.isEmpty
                  ? _EmptyMediaPreview(key: ValueKey(selected))
                  : _MediaPreviewGrid(
                      key: ValueKey(selected),
                      items: items.take(8).toList(growable: false),
                      onOpen: widget.onOpenAll,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaFilterChip extends StatelessWidget {
  const _MediaFilterChip({
    required this.icon,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = selected ? Colors.lightBlueAccent : Colors.white54;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Material(
          color: selected
              ? Colors.lightBlueAccent.withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.045),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected
                      ? Colors.lightBlueAccent.withValues(alpha: 0.32)
                      : Colors.white.withValues(alpha: 0.07),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: accent, size: 15),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      count > 0 ? '$label $count' : label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaPreviewGrid extends StatelessWidget {
  const _MediaPreviewGrid({
    super.key,
    required this.items,
    required this.onOpen,
  });

  final List<_ProfilePreviewItem> items;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 0.86,
      ),
      itemBuilder: (context, index) =>
          _MediaPreviewTile(item: items[index], onTap: onOpen),
    );
  }
}

class _MediaPreviewTile extends StatelessWidget {
  const _MediaPreviewTile({required this.item, required this.onTap});

  final _ProfilePreviewItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF101D2B),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _MediaPreviewContent(item: item),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            if (item.subtitle.isNotEmpty)
              Positioned(
                right: 6,
                bottom: 5,
                child: Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MediaPreviewContent extends StatelessWidget {
  const _MediaPreviewContent({required this.item});

  final _ProfilePreviewItem item;

  @override
  Widget build(BuildContext context) {
    switch (item.kind) {
      case _ProfilePreviewKind.image:
        final bytes = _tryDecodeHex(item.fileData);
        if (bytes != null) {
          return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
        }
        return const _PreviewIconTile(
          icon: Icons.image_outlined,
          title: 'Photo',
          color: Color(0xFF3BD6FF),
        );
      case _ProfilePreviewKind.video:
        return const _PreviewIconTile(
          icon: Icons.play_circle_outline_rounded,
          title: 'Video',
          color: Color(0xFFA56BFF),
        );
      case _ProfilePreviewKind.voice:
        return _VoicePreviewTile(title: item.title);
      case _ProfilePreviewKind.link:
        return _PreviewIconTile(
          icon: Icons.link_rounded,
          title: item.title,
          color: const Color(0xFF52E0C4),
        );
      case _ProfilePreviewKind.file:
        return _PreviewIconTile(
          icon: Icons.insert_drive_file_rounded,
          title: item.title,
          color: const Color(0xFF6CB6FF),
        );
    }
  }
}

class _PreviewIconTile extends StatelessWidget {
  const _PreviewIconTile({
    required this.icon,
    required this.title,
    required this.color,
  });

  final IconData icon;
  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(7),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 30),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _VoicePreviewTile extends StatelessWidget {
  const _VoicePreviewTile({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: CustomPaint(
              painter: _MiniWaveformPainter(),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 9, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

class _MiniWaveformPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const bars = [0.28, 0.62, 0.38, 0.82, 0.48, 0.72, 0.33, 0.58, 0.88, 0.42];
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.4
      ..shader = const LinearGradient(
        colors: [Color(0xFF3BD6FF), Color(0xFFA56BFF)],
      ).createShader(Offset.zero & size);
    final step = size.width / bars.length;
    for (var i = 0; i < bars.length; i++) {
      final x = step * i + step / 2;
      final h = size.height * bars[i];
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _EmptyMediaPreview extends StatelessWidget {
  const _EmptyMediaPreview({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: const Text(
        'Nothing here yet',
        style: TextStyle(color: Colors.white38, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _ProfileDangerActions extends StatelessWidget {
  const _ProfileDangerActions({
    required this.blocked,
    required this.onBlock,
    required this.onDeleteLocal,
    required this.onDeleteBoth,
  });

  final bool blocked;
  final VoidCallback onBlock;
  final VoidCallback onDeleteLocal;
  final VoidCallback onDeleteBoth;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _DangerTile(
          icon: blocked ? Icons.visibility_rounded : Icons.block_rounded,
          label: blocked ? 'Unblock' : 'Block',
          onTap: onBlock,
        ),
        _DangerTile(
          icon: Icons.delete_outline_rounded,
          label: 'Delete chat',
          onTap: onDeleteLocal,
        ),
        _DangerTile(
          icon: Icons.delete_forever_outlined,
          label: 'Delete for both',
          onTap: onDeleteBoth,
        ),
      ],
    );
  }
}

class _DangerTile extends StatelessWidget {
  const _DangerTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: _ProfileGlassSurface(
        radius: 20,
        child: ListTile(
          leading: Icon(icon, color: Colors.redAccent),
          title: Text(label, style: const TextStyle(color: Colors.redAccent)),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _ProfileGlassSurface extends StatelessWidget {
  const _ProfileGlassSurface({required this.child, required this.radius});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xE024303B),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.13)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );
  }
}

class _ProfileMediaBuckets {
  const _ProfileMediaBuckets({
    required this.media,
    required this.files,
    required this.voice,
    required this.links,
  });

  final List<_ProfilePreviewItem> media;
  final List<_ProfilePreviewItem> files;
  final List<_ProfilePreviewItem> voice;
  final List<_ProfilePreviewItem> links;

  factory _ProfileMediaBuckets.fromThread(ChatThread? thread) {
    if (thread == null) {
      return const _ProfileMediaBuckets(
        media: [],
        files: [],
        voice: [],
        links: [],
      );
    }
    final media = <_ProfilePreviewItem>[];
    final files = <_ProfilePreviewItem>[];
    final voice = <_ProfilePreviewItem>[];
    final links = <_ProfilePreviewItem>[];
    final messages =
        thread.messages.where((message) => !message.deleted).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    for (final message in messages) {
      if (message.kind == ChatMessageKind.file) {
        final fileName = message.fileName.trim().isEmpty
            ? 'File'
            : message.fileName.trim();
        if (_isImageName(fileName)) {
          media.add(
            _ProfilePreviewItem(
              kind: _ProfilePreviewKind.image,
              title: fileName,
              subtitle: '',
              fileData: message.fileData,
            ),
          );
        } else if (_isVideoName(fileName)) {
          media.add(
            _ProfilePreviewItem(
              kind: _ProfilePreviewKind.video,
              title: fileName,
              subtitle: _formatSize(message.fileSize),
            ),
          );
        } else if (_isAudioName(fileName)) {
          voice.add(
            _ProfilePreviewItem(
              kind: _ProfilePreviewKind.voice,
              title: fileName,
              subtitle: _formatSize(message.fileSize),
            ),
          );
        } else {
          files.add(
            _ProfilePreviewItem(
              kind: _ProfilePreviewKind.file,
              title: fileName,
              subtitle: _formatSize(message.fileSize),
            ),
          );
        }
      }
      for (final link in _extractLinks(message.text)) {
        links.add(
          _ProfilePreviewItem(
            kind: _ProfilePreviewKind.link,
            title: _linkTitle(link),
            subtitle: link,
          ),
        );
      }
    }

    return _ProfileMediaBuckets(
      media: media,
      files: files,
      voice: voice,
      links: links,
    );
  }

  List<_ProfilePreviewItem> itemsFor(_ProfileMediaTab tab) {
    switch (tab) {
      case _ProfileMediaTab.media:
        return media;
      case _ProfileMediaTab.files:
        return files;
      case _ProfileMediaTab.voice:
        return voice;
      case _ProfileMediaTab.links:
        return links;
    }
  }
}

class _ProfilePreviewItem {
  const _ProfilePreviewItem({
    required this.kind,
    required this.title,
    required this.subtitle,
    this.fileData = '',
  });

  final _ProfilePreviewKind kind;
  final String title;
  final String subtitle;
  final String fileData;
}

enum _ProfilePreviewKind { image, video, file, voice, link }

bool _isImageName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.bmp');
}

bool _isVideoName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.mp4') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.webm') ||
      lower.endsWith('.mkv') ||
      lower.endsWith('.avi');
}

bool _isAudioName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.mp3') ||
      lower.endsWith('.wav') ||
      lower.endsWith('.m4a') ||
      lower.endsWith('.aac') ||
      lower.endsWith('.ogg') ||
      lower.endsWith('.opus') ||
      lower.endsWith('.flac');
}

List<String> _extractLinks(String text) {
  final expression = RegExp(
    r'((https?:\/\/|www\.)[^\s<]+|t\.me\/[^\s<]+)',
    caseSensitive: false,
  );
  return expression
      .allMatches(text)
      .map((match) => match.group(0) ?? '')
      .where((link) => link.isNotEmpty)
      .take(8)
      .toList(growable: false);
}

String _linkTitle(String link) {
  final normalized = link.startsWith('http') ? link : 'https://$link';
  final uri = Uri.tryParse(normalized);
  final host = uri?.host;
  if (host != null && host.isNotEmpty) return host.replaceFirst('www.', '');
  return link;
}

String _formatSize(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb >= 10 ? 0 : 1)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
}

Uint8List? _tryDecodeHex(String value) {
  final source = value.trim();
  if (source.isEmpty || source.length.isOdd) return null;
  try {
    final bytes = Uint8List(source.length ~/ 2);
    for (var i = 0; i < source.length; i += 2) {
      bytes[i ~/ 2] = int.parse(source.substring(i, i + 2), radix: 16);
    }
    return bytes;
  } on FormatException {
    return null;
  }
}
