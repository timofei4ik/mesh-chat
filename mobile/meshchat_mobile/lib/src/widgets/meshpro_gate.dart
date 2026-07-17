import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/app_controller.dart';

const meshProPurchaseUrl = 'https://boosty.to/meshpro';

bool meshProFeatureEnabled(AppController controller, String featureId) {
  final subscription = controller.meshProSubscription;
  return subscription.isActiveNow &&
      subscription.entitlements.hasFeature(featureId);
}

String meshProRemainingLabel(AppController controller) {
  final subscription = controller.meshProSubscription;
  if (!subscription.isActiveNow) return 'No active subscription';
  if (subscription.periodEnd == null) return 'Active without an expiry date';
  final remaining = subscription.remaining;
  final days = remaining.inDays;
  final hours = remaining.inHours.remainder(24);
  final minutes = remaining.inMinutes.remainder(60);
  return '$days d $hours h $minutes min remaining';
}

String meshProExpiryLabel(AppController controller) {
  final end = controller.meshProSubscription.periodEnd;
  if (end == null) return '';
  final date =
      '${end.day.toString().padLeft(2, '0')}.'
      '${end.month.toString().padLeft(2, '0')}.${end.year} '
      '${end.hour.toString().padLeft(2, '0')}:'
      '${end.minute.toString().padLeft(2, '0')}';
  return 'Until $date';
}

Future<void> openMeshProPurchase(BuildContext context) async {
  final opened = await launchUrl(
    Uri.parse(meshProPurchaseUrl),
    mode: LaunchMode.externalApplication,
  );
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Could not open Boosty')));
  }
}

Future<void> showMeshProPaywall(
  BuildContext context,
  AppController controller, {
  String? featureId,
  String? featureTitle,
  String? featureDescription,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final subscription = controller.meshProSubscription;
        final active = subscription.isActiveNow;
        final available = featureId == null
            ? active
            : meshProFeatureEnabled(controller, featureId);
        final accent = active
            ? const Color(0xFF67F3C4)
            : const Color(0xFFB28AFF);
        return SafeArea(
          top: false,
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.88,
            ),
            margin: const EdgeInsets.all(10),
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
            decoration: BoxDecoration(
              color: const Color(0xF516202C),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.16),
                  blurRadius: 38,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.12),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Icon(
                        Icons.workspace_premium_rounded,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            active ? 'MeshPro active' : 'Unlock MeshPro',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            meshProRemainingLabel(controller),
                            style: TextStyle(color: accent),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (featureTitle != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    available ? '$featureTitle is available' : featureTitle,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (featureDescription?.isNotEmpty == true) ...[
                    const SizedBox(height: 5),
                    Text(
                      featureDescription!,
                      style: const TextStyle(color: Colors.white60),
                    ),
                  ],
                ],
                const SizedBox(height: 18),
                const Text(
                  'Everything included now',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 10),
                const Expanded(
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      primary: true,
                      child: Column(children: _meshProBenefitSections),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: controller.refreshMeshProSubscription,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Refresh'),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => openMeshProPurchase(sheetContext),
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: Text(
                          active ? 'Extend on Boosty' : 'Buy on Boosty',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<bool> requireMeshPro(
  BuildContext context,
  AppController controller, {
  required String featureId,
  required String title,
  required String description,
}) async {
  if (meshProFeatureEnabled(controller, featureId)) return true;
  await showMeshProPaywall(
    context,
    controller,
    featureId: featureId,
    featureTitle: title,
    featureDescription: description,
  );
  return false;
}

class MeshProGate extends StatelessWidget {
  const MeshProGate({
    super.key,
    required this.controller,
    required this.featureId,
    required this.title,
    required this.description,
    required this.child,
  });

  final AppController controller;
  final String featureId;
  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (meshProFeatureEnabled(controller, featureId)) return child;
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: () => showMeshProPaywall(
        context,
        controller,
        featureId: featureId,
        featureTitle: title,
        featureDescription: description,
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.055),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            const Icon(Icons.lock_outline_rounded, color: Color(0xFFB28AFF)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

const _meshProBenefitSections = <Widget>[
  _PaywallFeatureSection(
    icon: Icons.person_rounded,
    title: 'Profile and MeshStudio',
    features: [
      'MeshPro badge and animated avatar',
      'Animated banners, profile effects and linked presets',
      'Avatar frames, glow, accent color and emoji status',
    ],
  ),
  _PaywallFeatureSection(
    icon: Icons.palette_rounded,
    title: 'Chats and appearance',
    features: [
      'Animated chat backgrounds and per-chat themes',
      'Custom message bubbles and send effects',
      'Up to 20 custom quick reactions',
    ],
  ),
  _PaywallFeatureSection(
    icon: Icons.auto_stories_rounded,
    title: 'Stories',
    features: [
      'HD stories and videos up to 120 seconds',
      'Server archive for up to 365 days',
      'Extra reactions and up to 20 parallel stories',
    ],
  ),
  _PaywallFeatureSection(
    icon: Icons.call_rounded,
    title: 'Calls',
    features: [
      'HD audio and enhanced noise suppression',
      'Screen sharing during calls',
    ],
  ),
  _PaywallFeatureSection(
    icon: Icons.auto_awesome_rounded,
    title: 'Mesh AI',
    features: [
      'Rewrite text and translate messages',
      'Voice transcription and chat summaries',
      'OCR for images and documents',
      'Smart reply suggestions from chat context',
    ],
  ),
  _PaywallFeatureSection(
    icon: Icons.schedule_send_rounded,
    title: 'Scheduling',
    features: [
      'Scheduled messages and recurring reminders',
      'Scheduled channel posts',
    ],
  ),
  _PaywallFeatureSection(
    icon: Icons.devices_rounded,
    title: 'Devices',
    features: [
      'Extended multi-device controls',
      'Device naming and remote session management',
    ],
  ),
  _PaywallFeatureSection(
    icon: Icons.shield_rounded,
    title: 'MeshPrivacy',
    features: ['Private VPN access while MeshPro is active'],
  ),
];

class _PaywallFeatureSection extends StatelessWidget {
  const _PaywallFeatureSection({
    required this.icon,
    required this.title,
    required this.features,
  });

  final IconData icon;
  final String title;
  final List<String> features;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF67F3C4)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                for (final feature in features)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      '• $feature',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
