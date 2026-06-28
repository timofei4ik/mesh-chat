import 'dart:ui';

import 'package:cross_file/cross_file.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/chat_message.dart';
import '../models/chat_thread.dart';

enum MediaSection { media, files, voice, links }

class ChatMediaPage extends StatefulWidget {
  const ChatMediaPage({super.key, required this.thread});

  final ChatThread thread;

  @override
  State<ChatMediaPage> createState() => _ChatMediaPageState();
}

class _ChatMediaPageState extends State<ChatMediaPage> {
  MediaSection selected = MediaSection.media;

  @override
  Widget build(BuildContext context) {
    final buckets = _MediaBuckets.fromThread(widget.thread);
    final items = buckets.itemsFor(selected);

    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Row(
                children: [
                  _RoundGlassButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    onTap: () => Navigator.maybePop(context),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Shared media',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          widget.thread.profile.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: _GlassSurface(
                radius: 22,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      _TabButton(
                        icon: Icons.photo_library_outlined,
                        label: 'Media',
                        count: buckets.media.length,
                        selected: selected == MediaSection.media,
                        onTap: () =>
                            setState(() => selected = MediaSection.media),
                      ),
                      _TabButton(
                        icon: Icons.insert_drive_file_outlined,
                        label: 'Files',
                        count: buckets.files.length,
                        selected: selected == MediaSection.files,
                        onTap: () =>
                            setState(() => selected = MediaSection.files),
                      ),
                      _TabButton(
                        icon: Icons.keyboard_voice_outlined,
                        label: 'Voice',
                        count: buckets.voice.length,
                        selected: selected == MediaSection.voice,
                        onTap: () =>
                            setState(() => selected = MediaSection.voice),
                      ),
                      _TabButton(
                        icon: Icons.link_rounded,
                        label: 'Links',
                        count: buckets.links.length,
                        selected: selected == MediaSection.links,
                        onTap: () =>
                            setState(() => selected = MediaSection.links),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: items.isEmpty
                    ? const Center(
                        key: ValueKey('empty'),
                        child: Text(
                          'Nothing here yet',
                          style: TextStyle(color: Colors.white38),
                        ),
                      )
                    : _MediaContent(
                        key: ValueKey(selected),
                        section: selected,
                        items: items,
                        mediaItems: buckets.media,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaContent extends StatelessWidget {
  const _MediaContent({
    super.key,
    required this.section,
    required this.items,
    required this.mediaItems,
  });

  final MediaSection section;
  final List<_MediaItem> items;
  final List<_MediaItem> mediaItems;

  @override
  Widget build(BuildContext context) {
    if (section == MediaSection.files ||
        section == MediaSection.voice ||
        section == MediaSection.links) {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) => items[index].kind == _MediaKind.voice
            ? _VoiceListTile(item: items[index])
            : _ListMediaTile(item: items[index]),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 7,
        crossAxisSpacing: 7,
        childAspectRatio: 0.86,
      ),
      itemBuilder: (context, index) => _GridMediaTile(
        item: items[index],
        onTap: () {
          final photos = mediaItems
              .where(
                (item) => item.kind == _MediaKind.image && item.bytes != null,
              )
              .toList(growable: false);
          final photoIndex = photos.indexWhere(
            (item) => item.message.id == items[index].message.id,
          );
          if (photoIndex >= 0) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    _PhotoViewerPage(photos: photos, initialIndex: photoIndex),
              ),
            );
          }
        },
      ),
    );
  }
}

class _GridMediaTile extends StatelessWidget {
  const _GridMediaTile({required this.item, required this.onTap});

  final _MediaItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF101D2B),
      borderRadius: BorderRadius.circular(15),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (item.bytes != null)
              Image.memory(
                item.bytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            else
              _CenteredPreviewIcon(item: item),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
            ),
            Positioned(
              right: 7,
              bottom: 6,
              child: Text(
                _shortTime(item.message.createdAt),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  shadows: [Shadow(blurRadius: 5, color: Colors.black)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListMediaTile extends StatelessWidget {
  const _ListMediaTile({required this.item});

  final _MediaItem item;

  @override
  Widget build(BuildContext context) {
    return _GlassSurface(
      radius: 18,
      child: ListTile(
        leading: SizedBox(
          width: 46,
          height: 46,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: item.bytes != null
                ? Image.memory(item.bytes!, fit: BoxFit.cover)
                : _CenteredPreviewIcon(item: item),
          ),
        ),
        title: Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          item.subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white54),
        ),
        onTap: () => _handleItemTap(context, item),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          color: Colors.white38,
        ),
      ),
    );
  }

  Future<void> _handleItemTap(BuildContext context, _MediaItem item) async {
    if (item.kind == _MediaKind.link) {
      await Clipboard.setData(ClipboardData(text: item.subtitle));
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Link copied')));
      }
      return;
    }
    if (item.message.kind != ChatMessageKind.file ||
        item.message.fileData.isEmpty ||
        kIsWeb) {
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      final filename = _safeFilename(item.message.fileName);
      final path = p.join(dir.path, filename);
      await XFile.fromData(
        _hexDecode(item.message.fileData),
        name: filename,
      ).saveTo(path);
      await OpenFilex.open(path);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open file')));
    }
  }
}

class _CenteredPreviewIcon extends StatelessWidget {
  const _CenteredPreviewIcon({required this.item});

  final _MediaItem item;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (item.kind) {
      _MediaKind.image => (Icons.image_outlined, const Color(0xFF3BD6FF)),
      _MediaKind.video => (
        Icons.play_circle_outline_rounded,
        const Color(0xFFA56BFF),
      ),
      _MediaKind.voice => (Icons.graphic_eq_rounded, const Color(0xFF52E0C4)),
      _MediaKind.link => (Icons.link_rounded, const Color(0xFF3BD6FF)),
      _MediaKind.file => (
        Icons.insert_drive_file_rounded,
        const Color(0xFF6CB6FF),
      ),
    };
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF101D2B)),
      child: Center(child: Icon(icon, color: color, size: 30)),
    );
  }
}

class _PhotoViewerPage extends StatefulWidget {
  const _PhotoViewerPage({required this.photos, required this.initialIndex});

  final List<_MediaItem> photos;
  final int initialIndex;

  @override
  State<_PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<_PhotoViewerPage> {
  late final PageController controller;
  late int index;

  @override
  void initState() {
    super.initState();
    index = widget.initialIndex;
    controller = PageController(initialPage: index);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: controller,
              itemCount: widget.photos.length,
              onPageChanged: (value) => setState(() => index = value),
              itemBuilder: (context, page) {
                final bytes = widget.photos[page].bytes;
                return InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
                  child: Center(
                    child: bytes == null
                        ? const Icon(Icons.broken_image_outlined)
                        : Image.memory(bytes, fit: BoxFit.contain),
                  ),
                );
              },
            ),
            Positioned(
              top: 8,
              left: 8,
              child: _RoundGlassButton(
                icon: Icons.close_rounded,
                onTap: () => Navigator.maybePop(context),
              ),
            ),
            Positioned(
              top: 21,
              right: 18,
              child: Text(
                '${index + 1}/${widget.photos.length}',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            Positioned(
              right: 14,
              bottom: 22,
              child: Row(
                children: [
                  _RoundGlassButton(
                    icon: Icons.download_rounded,
                    onTap: () => _saveCurrent(context),
                  ),
                  const SizedBox(width: 10),
                  _RoundGlassButton(
                    icon: Icons.info_outline_rounded,
                    onTap: () => _showCurrentInfo(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveCurrent(BuildContext context) async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saving is not available on web')),
      );
      return;
    }
    final item = widget.photos[index];
    final bytes = item.bytes;
    if (bytes == null) return;
    try {
      final dir =
          await getDownloadsDirectory() ?? await getTemporaryDirectory();
      final filename = _safeFilename(item.message.fileName);
      final path = p.join(dir.path, filename);
      await XFile.fromData(bytes, name: filename).saveTo(path);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved: $filename')));
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not save photo')));
    }
  }

  void _showCurrentInfo(BuildContext context) {
    final item = widget.photos[index];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
          child: _GlassSurface(
            radius: 24,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.subtitle,
                    style: const TextStyle(color: Colors.white60),
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

class _VoiceListTile extends StatefulWidget {
  const _VoiceListTile({required this.item});

  final _MediaItem item;

  @override
  State<_VoiceListTile> createState() => _VoiceListTileState();
}

class _VoiceListTileState extends State<_VoiceListTile> {
  late final AudioPlayer player;
  Duration duration = Duration.zero;
  Duration position = Duration.zero;
  bool playing = false;
  bool sourceReady = false;

  @override
  void initState() {
    super.initState();
    player = AudioPlayer();
    player.onDurationChanged.listen((value) {
      if (mounted) setState(() => duration = value);
    });
    player.onPositionChanged.listen((value) {
      if (mounted) setState(() => position = value);
    });
    player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        playing = false;
        position = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  Future<void> toggle() async {
    if (playing) {
      await player.pause();
      if (mounted) setState(() => playing = false);
      return;
    }
    try {
      if (!sourceReady) {
        await player.setSource(
          BytesSource(_hexDecode(widget.item.message.fileData)),
        );
        sourceReady = true;
      }
      await player.resume();
      if (mounted) setState(() => playing = true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not play voice')));
    }
  }

  Future<void> seek(double fraction) async {
    if (duration <= Duration.zero) return;
    final target = Duration(
      milliseconds: (duration.inMilliseconds * fraction.clamp(0.0, 1.0))
          .round(),
    );
    await player.seek(target);
    if (mounted) setState(() => position = target);
  }

  @override
  Widget build(BuildContext context) {
    final progress = duration.inMilliseconds <= 0
        ? 0.0
        : position.inMilliseconds / duration.inMilliseconds;
    return _GlassSurface(
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            IconButton.filled(
              onPressed: toggle,
              icon: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 7),
                  _MiniVoiceWaveform(
                    progress: progress,
                    active: playing,
                    onSeek: seek,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    duration > Duration.zero
                        ? '${_durationText(position)} / ${_durationText(duration)}'
                        : widget.item.subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniVoiceWaveform extends StatelessWidget {
  const _MiniVoiceWaveform({
    required this.progress,
    required this.active,
    required this.onSeek,
  });

  final double progress;
  final bool active;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    const levels = [
      0.25,
      0.58,
      0.35,
      0.80,
      0.48,
      0.68,
      0.30,
      0.92,
      0.45,
      0.62,
      0.78,
      0.38,
      0.56,
      0.86,
      0.33,
      0.70,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        void seek(Offset position) {
          if (constraints.maxWidth <= 0) return;
          onSeek(position.dx / constraints.maxWidth);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => seek(details.localPosition),
          onHorizontalDragUpdate: (details) => seek(details.localPosition),
          child: SizedBox(
            height: 28,
            child: Row(
              children: [
                for (var i = 0; i < levels.length; i++)
                  Expanded(
                    child: Align(
                      child: FractionallySizedBox(
                        heightFactor: levels[i],
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 1.2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: i < (levels.length * progress).round()
                                ? Colors.lightBlueAccent
                                : Colors.white.withValues(
                                    alpha: active ? 0.40 : 0.25,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
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
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected
                      ? Colors.lightBlueAccent.withValues(alpha: 0.30)
                      : Colors.white.withValues(alpha: 0.07),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    color: selected ? Colors.lightBlueAccent : Colors.white54,
                    size: 15,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      count > 0 ? '$label $count' : label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: selected ? Colors.white : Colors.white70,
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

class _RoundGlassButton extends StatelessWidget {
  const _RoundGlassButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Material(
          color: Colors.white.withValues(alpha: 0.10),
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(icon, color: Colors.white70, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassSurface extends StatelessWidget {
  const _GlassSurface({required this.child, required this.radius});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xAA182634),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.11)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _MediaBuckets {
  const _MediaBuckets({
    required this.media,
    required this.files,
    required this.voice,
    required this.links,
  });

  final List<_MediaItem> media;
  final List<_MediaItem> files;
  final List<_MediaItem> voice;
  final List<_MediaItem> links;

  factory _MediaBuckets.fromThread(ChatThread thread) {
    final media = <_MediaItem>[];
    final files = <_MediaItem>[];
    final voice = <_MediaItem>[];
    final links = <_MediaItem>[];
    final messages =
        thread.messages.where((message) => !message.deleted).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    for (final message in messages) {
      if (message.kind == ChatMessageKind.file) {
        final name = message.fileName.trim().isEmpty
            ? 'File'
            : message.fileName;
        final subtitle = [
          if (message.fileSize > 0) _formatSize(message.fileSize),
          _shortDate(message.createdAt),
        ].join(' · ');
        final bytes = _isImageName(name)
            ? _tryHexDecode(message.fileData)
            : null;
        final item = _MediaItem(
          message: message,
          kind: _kindForName(name),
          title: name,
          subtitle: subtitle,
          bytes: bytes,
        );
        switch (item.kind) {
          case _MediaKind.image:
          case _MediaKind.video:
            media.add(item);
          case _MediaKind.voice:
            voice.add(item);
          case _MediaKind.file:
          case _MediaKind.link:
            files.add(item);
        }
      }
      for (final link in _extractLinks(message.text)) {
        links.add(
          _MediaItem(
            message: message,
            kind: _MediaKind.link,
            title: _linkTitle(link),
            subtitle: link,
          ),
        );
      }
    }

    return _MediaBuckets(
      media: media,
      files: files,
      voice: voice,
      links: links,
    );
  }

  List<_MediaItem> itemsFor(MediaSection section) => switch (section) {
    MediaSection.media => media,
    MediaSection.files => files,
    MediaSection.voice => voice,
    MediaSection.links => links,
  };
}

class _MediaItem {
  const _MediaItem({
    required this.message,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.bytes,
  });

  final ChatMessage message;
  final _MediaKind kind;
  final String title;
  final String subtitle;
  final Uint8List? bytes;
}

enum _MediaKind { image, video, file, voice, link }

_MediaKind _kindForName(String name) {
  if (_isImageName(name)) return _MediaKind.image;
  if (_isVideoName(name)) return _MediaKind.video;
  if (_isAudioName(name)) return _MediaKind.voice;
  return _MediaKind.file;
}

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
      .toList(growable: false);
}

String _linkTitle(String link) {
  final normalized = link.startsWith('http') ? link : 'https://$link';
  final uri = Uri.tryParse(normalized);
  return uri?.host.replaceFirst('www.', '') ?? link;
}

Uint8List? _tryHexDecode(String value) {
  if (value.isEmpty || value.length.isOdd) return null;
  try {
    return _hexDecode(value);
  } on FormatException {
    return null;
  }
}

Uint8List _hexDecode(String hex) {
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

String _safeFilename(String name) {
  final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return safe.isEmpty ? 'meshchat_file' : safe;
}

String _formatSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}

String _shortTime(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String _shortDate(DateTime value) {
  final local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}.'
      '${local.month.toString().padLeft(2, '0')}.'
      '${local.year}';
}

String _durationText(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
