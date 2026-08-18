import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const _legalBaseUrl = 'https://meshchat-losa.ru/meshpro/legal';

class LegalSafetyPage extends StatelessWidget {
  const LegalSafetyPage({super.key});

  Future<void> _open(BuildContext context, String path) async {
    final opened = await launchUrl(
      Uri.parse('$_legalBaseUrl/$path'),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open this page')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Legal & Safety'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _LegalTile(
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy',
            subtitle: 'Data collection, use, retention and your rights',
            onTap: () => _open(context, 'privacy'),
          ),
          _LegalTile(
            icon: Icons.description_outlined,
            title: 'Terms of Service',
            subtitle: 'Rules for using MeshChat and MeshPro',
            onTap: () => _open(context, 'terms'),
          ),
          _LegalTile(
            icon: Icons.groups_outlined,
            title: 'Community Guidelines',
            subtitle: 'Safety rules and how moderation works',
            onTap: () => _open(context, 'community'),
          ),
          _LegalTile(
            icon: Icons.support_agent_rounded,
            title: 'Support',
            subtitle: 'Contact, safety and account help',
            onTap: () => _open(context, 'support'),
          ),
          _LegalTile(
            icon: Icons.delete_forever_outlined,
            title: 'Account deletion on the web',
            subtitle: 'Delete an account even without the installed app',
            danger: true,
            onTap: () => _open(context, 'account-deletion'),
          ),
        ],
      ),
    );
  }
}

class _LegalTile extends StatelessWidget {
  const _LegalTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final accent = danger ? Colors.redAccent : const Color(0xFF72D8FF);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: const Color(0xFF1A2735),
        child: ListTile(
          leading: Icon(icon, color: accent),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: onTap,
        ),
      ),
    );
  }
}
