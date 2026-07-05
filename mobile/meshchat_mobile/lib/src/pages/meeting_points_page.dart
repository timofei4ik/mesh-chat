import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/app_controller.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';

class MeetingPointsPage extends StatelessWidget {
  const MeetingPointsPage({
    super.key,
    required this.controller,
    required this.thread,
  });

  final AppController controller;
  final ChatThread thread;

  @override
  Widget build(BuildContext context) {
    final points = _MeetingPointEntry.fromThread(thread);
    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      body: Stack(
        children: [
          const Positioned.fill(child: _MapMeshBackground()),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
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
                              'Meeting points',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              thread.profile.displayName,
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
                Expanded(
                  child: points.isEmpty
                      ? const _EmptyMeetingPoints()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
                          itemCount: points.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final entry = points[index];
                            return _MeetingPointTile(
                              entry: entry,
                              senderName: _senderName(entry.message),
                              onJump: () =>
                                  Navigator.pop(context, entry.message.id),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _senderName(ChatMessage message) {
    if (message.senderNode == controller.myNodeId) return 'you';
    final profile = controller.profiles[message.senderNode];
    if (profile != null && profile.displayName.trim().isNotEmpty) {
      return profile.displayName.trim();
    }
    final id = message.senderNode.trim();
    if (id.isEmpty) return 'unknown';
    return id.length <= 8 ? id : id.substring(0, 8);
  }
}

class _MeetingPointTile extends StatelessWidget {
  const _MeetingPointTile({
    required this.entry,
    required this.senderName,
    required this.onJump,
  });

  final _MeetingPointEntry entry;
  final String senderName;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    final point = entry.point;
    final time = entry.message.createdAt.toLocal();
    final timestamp =
        '${time.day.toString().padLeft(2, '0')}.'
        '${time.month.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    return _GlassSurface(
      radius: 24,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onJump,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [Color(0xFF45D9FF), Color(0xFF9A63FF)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.lightBlueAccent.withValues(alpha: 0.24),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.location_on_rounded,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          point.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${point.coordinateLabel} - $senderName - $timestamp',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (point.note.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  point.note.trim(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
              const SizedBox(height: 13),
              Row(
                children: [
                  Expanded(
                    child: _PillButton(
                      icon: Icons.map_rounded,
                      label: 'Open',
                      onTap: () => point.open(context, route: false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _PillButton(
                      icon: Icons.near_me_rounded,
                      label: 'Route',
                      onTap: () => point.open(context, route: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _PillButton(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: 'Message',
                    onTap: onJump,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyMeetingPoints extends StatelessWidget {
  const _EmptyMeetingPoints();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: _GlassSurface(
          radius: 28,
          child: const Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.add_location_alt_outlined,
                  color: Colors.lightBlueAccent,
                  size: 44,
                ),
                SizedBox(height: 12),
                Text(
                  'No meeting points yet',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                ),
                SizedBox(height: 6),
                Text(
                  'Attach a meeting point in this group, and it will appear here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
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
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      ),
    );
  }
}

class _GlassSurface extends StatelessWidget {
  const _GlassSurface({required this.child, this.radius = 22});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF172333).withValues(alpha: 0.68),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _MapMeshBackground extends StatelessWidget {
  const _MapMeshBackground();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _MapMeshPainter());
  }
}

class _MapMeshPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paintLine = Paint()
      ..color = Colors.white.withValues(alpha: 0.045)
      ..strokeWidth = 1;
    final paintDot = Paint()..color = Colors.white.withValues(alpha: 0.10);
    final points = [
      Offset(size.width * 0.08, size.height * 0.20),
      Offset(size.width * 0.28, size.height * 0.11),
      Offset(size.width * 0.48, size.height * 0.26),
      Offset(size.width * 0.70, size.height * 0.17),
      Offset(size.width * 0.88, size.height * 0.32),
      Offset(size.width * 0.18, size.height * 0.58),
      Offset(size.width * 0.42, size.height * 0.70),
      Offset(size.width * 0.78, size.height * 0.62),
    ];
    for (var i = 0; i < points.length - 1; i++) {
      canvas.drawLine(points[i], points[i + 1], paintLine);
    }
    canvas.drawLine(points[0], points[6], paintLine);
    canvas.drawLine(points[2], points[5], paintLine);
    canvas.drawLine(points[4], points[7], paintLine);
    for (final point in points) {
      canvas.drawCircle(point, 2, paintDot);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MeetingPointEntry {
  const _MeetingPointEntry({required this.message, required this.point});

  final ChatMessage message;
  final _MeetingPoint point;

  static List<_MeetingPointEntry> fromThread(ChatThread thread) {
    final result = <_MeetingPointEntry>[];
    for (final message in thread.messages) {
      if (message.deleted) continue;
      final point = _MeetingPoint.fromMessageText(message.text);
      if (point == null) continue;
      result.add(_MeetingPointEntry(message: message, point: point));
    }
    return result.reversed.toList();
  }
}

class _MeetingPoint {
  const _MeetingPoint({
    required this.title,
    required this.latitude,
    required this.longitude,
    this.note = '',
  });

  static const prefix = '::meshchat_meeting_v1::';

  final String title;
  final double latitude;
  final double longitude;
  final String note;

  String get coordinateLabel {
    return '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
  }

  static _MeetingPoint? fromMessageText(String text) {
    if (!text.startsWith(prefix)) return null;
    try {
      final raw = jsonDecode(text.substring(prefix.length));
      if (raw is! Map) return null;
      final lat = double.tryParse(raw['lat']?.toString() ?? '');
      final lng = double.tryParse(raw['lng']?.toString() ?? '');
      if (lat == null || lng == null || !_validCoordinates(lat, lng)) {
        return null;
      }
      return _MeetingPoint(
        title: raw['title']?.toString().trim().isEmpty == false
            ? raw['title'].toString().trim()
            : 'Meeting point',
        latitude: lat,
        longitude: lng,
        note: raw['note']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  static bool _validCoordinates(double lat, double lng) {
    return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  Future<void> open(BuildContext context, {required bool route}) async {
    final destination = '$latitude,$longitude';
    final uri = route
        ? Uri.parse(
            'https://www.google.com/maps/dir/?api=1&destination=$destination',
          )
        : Uri.parse(
            'https://www.google.com/maps/search/?api=1&query=$destination',
          );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Could not open map')));
  }
}
