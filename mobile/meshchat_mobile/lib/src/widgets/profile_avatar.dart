import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/profile.dart';

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.profile, this.radius = 24});

  final Profile profile;
  final double radius;

  static final Map<String, MemoryImage> _imageCache = {};

  @override
  Widget build(BuildContext context) {
    final image = _avatarImage(profile.avatarData);
    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0xFF315A7D),
          shape: BoxShape.circle,
        ),
        child: ClipOval(
          child: image == null
              ? Center(
                  child: Text(
                    _initials(profile.displayName),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: radius * 0.58,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              : Image(
                  image: image,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                ),
        ),
      ),
    );
  }

  static MemoryImage? _avatarImage(String value) {
    if (value.isEmpty) return null;
    final cached = _imageCache[value];
    if (cached != null) return cached;
    final bytes = _avatarBytes(value);
    if (bytes == null) return null;
    if (_imageCache.length > 80) _imageCache.clear();
    return _imageCache[value] = MemoryImage(bytes);
  }

  static Uint8List? _avatarBytes(String value) {
    if (value.isEmpty) return null;
    final comma = value.indexOf(',');
    final raw = comma >= 0 ? value.substring(comma + 1) : value;
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final result = parts
        .take(2)
        .where((part) => part.isNotEmpty)
        .map((part) => part.characters.first.toUpperCase())
        .join();
    return result.isEmpty ? '?' : result;
  }
}
