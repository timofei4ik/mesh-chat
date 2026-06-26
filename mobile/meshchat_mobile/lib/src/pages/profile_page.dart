import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../widgets/profile_avatar.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key, required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final username = profile.publicUsername.isEmpty
        ? ''
        : '@${profile.publicUsername}';
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        children: [
          Center(child: ProfileAvatar(profile: profile, radius: 56)),
          const SizedBox(height: 18),
          Text(
            profile.displayName,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (username.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              username,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60),
            ),
          ],
          const SizedBox(height: 12),
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: profile.online
                    ? Colors.greenAccent.withValues(alpha: 0.12)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  profile.online ? 'online' : 'offline',
                  style: TextStyle(
                    color: profile.online ? Colors.greenAccent : Colors.white60,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          if (profile.about.trim().isNotEmpty)
            _InfoTile(
              icon: Icons.info_outline,
              title: 'About',
              value: profile.about.trim(),
            ),
          _InfoTile(
            icon: Icons.fingerprint,
            title: 'ID',
            value: profile.nodeId,
          ),
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF20242B),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.white54),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white54)),
                const SizedBox(height: 4),
                SelectableText(value),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
