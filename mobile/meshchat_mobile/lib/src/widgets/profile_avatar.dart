import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/profile.dart';

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.profile, this.radius = 24});

  final Profile profile;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final bytes = _avatarBytes(profile.avatarData);
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFF315A7D),
      backgroundImage: bytes == null ? null : MemoryImage(bytes),
      child: bytes == null
          ? Text(
              _initials(profile.displayName),
              style: TextStyle(
                color: Colors.white,
                fontSize: radius * 0.58,
                fontWeight: FontWeight.w700,
              ),
            )
          : null,
    );
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
