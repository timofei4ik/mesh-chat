import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/mesh_studio_style.dart';
import '../models/profile.dart';
import '../widgets/meshpro_badge.dart';
import '../widgets/meshpro_gate.dart';
import '../widgets/message_send_effect.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/profile_effect_background.dart';

class MeshStudioPage extends StatefulWidget {
  const MeshStudioPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<MeshStudioPage> createState() => _MeshStudioPageState();
}

class _MeshStudioPageState extends State<MeshStudioPage> {
  late String profileBackground;
  late String profileEffect;
  late String profileBlinkShape;
  late String avatarDecoration;
  late bool profileGlow;
  late int profileAccent;

  bool saving = false;
  int messagePreviewRevision = 0;

  bool get studioAvailable =>
      meshProFeatureEnabled(widget.controller, 'profile_background');

  String get selectedPresetId => matchingMeshStudioPreset(
    background: profileBackground,
    effect: profileEffect,
    blink: profileBlinkShape,
    decoration: avatarDecoration,
    accent: profileAccent,
  );

  Profile get previewProfile {
    return widget.controller.ownProfile.copyWith(
      meshProBadge: true,
      profileBackground: profileBackground,
      profileEffect: profileEffect,
      profileBlinkShape: profileBlinkShape,
      avatarDecoration: avatarDecoration,
      profileGlow: profileGlow,
      profileAccent: profileAccent,
    );
  }

  @override
  void initState() {
    super.initState();
    final profile = widget.controller.ownProfile;
    profileBackground = profile.effectiveProfileBanner;
    profileEffect = profile.effectiveProfileEffect;
    profileBlinkShape = profile.effectiveProfileBlinkShape;
    avatarDecoration = profile.effectiveAvatarDecoration;
    profileGlow = profile.effectiveProfileGlow;
    profileAccent = profile.effectiveProfileAccent;
  }

  void applyPreset(MeshStudioPreset preset) {
    setState(() {
      profileBackground = preset.background;
      profileEffect = preset.effect;
      profileBlinkShape = preset.blink;
      avatarDecoration = preset.decoration;
      profileAccent = preset.accent;
      profileGlow = true;
      messagePreviewRevision++;
    });
  }

  Future<void> save() async {
    if (saving) return;
    if (!studioAvailable) {
      await showMeshProPaywall(
        context,
        widget.controller,
        featureId: 'profile_background',
        featureTitle: 'MeshStudio',
        featureDescription:
            'Create a linked MeshPro profile style with live previews.',
      );
      return;
    }

    setState(() => saving = true);
    try {
      final current = widget.controller.ownProfile;
      final error = await widget.controller.updateProfile(
        displayName: current.displayName,
        publicUsername: current.publicUsername,
        about: current.about,
        avatarData: current.avatarData,
        profileBackground:
            meshProFeatureEnabled(widget.controller, 'profile_background')
            ? profileBackground
            : null,
        profileEffect:
            meshProFeatureEnabled(widget.controller, 'profile_effect')
            ? profileEffect
            : null,
        profileBlinkShape:
            meshProFeatureEnabled(widget.controller, 'profile_effect')
            ? profileBlinkShape
            : null,
        avatarDecoration:
            meshProFeatureEnabled(widget.controller, 'animated_avatar')
            ? avatarDecoration
            : null,
        profileGlow: meshProFeatureEnabled(widget.controller, 'profile_glow')
            ? profileGlow
            : null,
        profileAccent: meshProFeatureEnabled(widget.controller, 'custom_accent')
            ? profileAccent
            : null,
        emojiStatus: current.emojiStatus,
      );
      if (!mounted) return;
      if (error != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error)));
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('MeshStudio appearance saved')),
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save MeshStudio: $error')),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(scaffoldBackgroundColor: const Color(0xFF07111E)),
      child: Scaffold(
        backgroundColor: const Color(0xFF07111E),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          titleSpacing: 4,
          title: const Text('MeshStudio'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: IconButton.filledTonal(
                tooltip: 'Save MeshStudio appearance',
                onPressed: saving ? null : save,
                icon: saving
                    ? const SizedBox.square(
                        dimension: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
              ),
            ),
          ],
        ),
        body: studioAvailable
            ? LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 920;
                  final preview = _StudioPreview(
                    profile: previewProfile,
                    messagePreviewRevision: messagePreviewRevision,
                    onReplay: () => setState(() => messagePreviewRevision++),
                  );
                  final controls = _StudioControls(
                    profile: previewProfile,
                    selectedPresetId: selectedPresetId,
                    profileBackground: profileBackground,
                    profileEffect: profileEffect,
                    profileBlinkShape: profileBlinkShape,
                    avatarDecoration: avatarDecoration,
                    profileGlow: profileGlow,
                    profileAccent: profileAccent,
                    onPreset: applyPreset,
                    onBackground: (value) =>
                        setState(() => profileBackground = value),
                    onEffect: (value) => setState(() => profileEffect = value),
                    onBlinkShape: (value) =>
                        setState(() => profileBlinkShape = value),
                    onDecoration: (value) => setState(() {
                      avatarDecoration = value;
                      messagePreviewRevision++;
                    }),
                    onGlow: (value) => setState(() => profileGlow = value),
                    onAccent: (value) => setState(() => profileAccent = value),
                  );
                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      wide ? 24 : 14,
                      14,
                      wide ? 24 : 14,
                      34,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1320),
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 9, child: preview),
                                  const SizedBox(width: 18),
                                  Expanded(flex: 11, child: controls),
                                ],
                              )
                            : Column(
                                children: [
                                  preview,
                                  const SizedBox(height: 14),
                                  controls,
                                ],
                              ),
                      ),
                    ),
                  );
                },
              )
            : _StudioLocked(controller: widget.controller),
      ),
    );
  }
}

class _StudioPreview extends StatelessWidget {
  const _StudioPreview({
    required this.profile,
    required this.messagePreviewRevision,
    required this.onReplay,
  });

  final Profile profile;
  final int messagePreviewRevision;
  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    final accent = Color(profile.effectiveProfileAccent);
    final messageEffect = profile.effectiveMessageEffect;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StudioPanel(
          title: 'Live profile',
          subtitle: 'Exactly how your public profile style will appear.',
          icon: Icons.visibility_outlined,
          child: Container(
            key: const ValueKey('mesh-studio-live-profile'),
            width: double.infinity,
            height: 310,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: _bannerBaseColor(profile.effectiveProfileBanner),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: accent.withValues(alpha: 0.28)),
              boxShadow: profile.effectiveProfileGlow
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.16),
                        blurRadius: 30,
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: ProfileEffectBackground(
                    profile: profile,
                    enabled: true,
                  ),
                ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: EdgeInsets.all(
                        profile.effectiveAvatarDecoration == 'none' ? 5 : 0,
                      ),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: profile.effectiveAvatarDecoration == 'none'
                            ? Border.all(color: accent.withValues(alpha: 0.72))
                            : null,
                        boxShadow: profile.effectiveProfileGlow
                            ? [
                                BoxShadow(
                                  color: accent.withValues(alpha: 0.40),
                                  blurRadius: 34,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                      child: ProfileAvatar(profile: profile, radius: 64),
                    ),
                    const SizedBox(height: 16),
                    MeshProProfileName(
                      profile: profile,
                      animate: true,
                      badgeSize: 19,
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (profile.publicUsername.trim().isNotEmpty)
                      Text(
                        '@${profile.publicUsername.trim()}',
                        style: const TextStyle(color: Colors.white60),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _StudioPanel(
          title: 'Message effect',
          subtitle: messageEffect == 'none'
              ? 'Choose a linked preset to add a one-shot send effect.'
              : '${_titleCase(messageEffect)} plays once when a message is sent.',
          icon: Icons.chat_bubble_outline_rounded,
          trailing: IconButton.filledTonal(
            tooltip: 'Replay message effect',
            onPressed: messageEffect == 'none' ? null : onReplay,
            icon: const Icon(Icons.replay_rounded),
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: MessageSendEffect(
              messageId: 'mesh-studio-$messagePreviewRevision',
              effect: messageEffect,
              enabled: messageEffect != 'none',
              child: Container(
                constraints: const BoxConstraints(maxWidth: 300),
                padding: const EdgeInsets.fromLTRB(16, 11, 16, 10),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.76),
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.18),
                  ),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'MeshStudio style is ready',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'now  ✓✓',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StudioControls extends StatelessWidget {
  const _StudioControls({
    required this.profile,
    required this.selectedPresetId,
    required this.profileBackground,
    required this.profileEffect,
    required this.profileBlinkShape,
    required this.avatarDecoration,
    required this.profileGlow,
    required this.profileAccent,
    required this.onPreset,
    required this.onBackground,
    required this.onEffect,
    required this.onBlinkShape,
    required this.onDecoration,
    required this.onGlow,
    required this.onAccent,
  });

  final Profile profile;
  final String selectedPresetId;
  final String profileBackground;
  final String profileEffect;
  final String profileBlinkShape;
  final String avatarDecoration;
  final bool profileGlow;
  final int profileAccent;
  final ValueChanged<MeshStudioPreset> onPreset;
  final ValueChanged<String> onBackground;
  final ValueChanged<String> onEffect;
  final ValueChanged<String> onBlinkShape;
  final ValueChanged<String> onDecoration;
  final ValueChanged<bool> onGlow;
  final ValueChanged<int> onAccent;

  @override
  Widget build(BuildContext context) {
    final accent = Color(profileAccent);
    return Column(
      children: [
        _StudioPanel(
          title: 'Linked presets',
          subtitle: 'One choice links the banner, frame, name and send effect.',
          icon: Icons.style_outlined,
          child: SizedBox(
            height: 94,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: meshStudioPresets.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final preset = meshStudioPresets[index];
                final selected = selectedPresetId == preset.id;
                final color = Color(preset.accent);
                return Tooltip(
                  message: 'Apply the ${preset.label} preset',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => onPreset(preset),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      width: 112,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: selected ? 0.19 : 0.06),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: color.withValues(
                            alpha: selected ? 0.78 : 0.18,
                          ),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedRotation(
                            turns: selected ? 0.125 : 0,
                            duration: const Duration(milliseconds: 260),
                            child: Icon(
                              Icons.auto_awesome_rounded,
                              color: color,
                              size: 23,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            preset.label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: selected
                                  ? FontWeight.w900
                                  : FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 14),
        _StudioPanel(
          title: 'Banner and animation',
          subtitle: 'Fine tune the background independently from a preset.',
          icon: Icons.wallpaper_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _ControlLabel('Profile banner'),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: meshStudioBackgrounds.map((option) {
                  return ChoiceChip(
                    label: Text(option.$2),
                    selected: profileBackground == option.$1,
                    onSelected: (_) => onBackground(option.$1),
                  );
                }).toList(),
              ),
              const SizedBox(height: 18),
              const _ControlLabel('Animated detail'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CompactChoice(
                    label: 'Sparkles',
                    icon: Icons.auto_awesome_rounded,
                    selected: profileEffect == 'stars',
                    onTap: () => onEffect('stars'),
                  ),
                  _CompactChoice(
                    label: 'Nodes',
                    icon: Icons.scatter_plot_outlined,
                    selected: profileEffect == 'nodes',
                    onTap: () => onEffect('nodes'),
                  ),
                  _CompactChoice(
                    label: 'Orbit',
                    icon: Icons.blur_circular_rounded,
                    selected: profileEffect == 'orbit',
                    onTap: () => onEffect('orbit'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const _ControlLabel('Blink shape'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CompactChoice(
                    label: 'Dot',
                    icon: Icons.circle,
                    selected: profileBlinkShape == 'dot',
                    onTap: () => onBlinkShape('dot'),
                  ),
                  _CompactChoice(
                    label: 'Star',
                    icon: Icons.auto_awesome_rounded,
                    selected: profileBlinkShape == 'star',
                    onTap: () => onBlinkShape('star'),
                  ),
                  _CompactChoice(
                    label: 'Moose',
                    leading: const Text(
                      '\u{10082}',
                      style: TextStyle(
                        fontFamily: 'NotoSansLinearB',
                        fontSize: 19,
                        height: 1,
                      ),
                    ),
                    selected: profileBlinkShape == 'moose',
                    onTap: () => onBlinkShape('moose'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _StudioPanel(
          title: 'Avatar frame',
          subtitle:
              'Large profile avatars animate; lists use an efficient still frame.',
          icon: Icons.account_circle_outlined,
          child: SizedBox(
            height: 103,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: meshStudioAvatarDecorations.length,
              separatorBuilder: (_, _) => const SizedBox(width: 7),
              itemBuilder: (context, index) {
                final option = meshStudioAvatarDecorations[index];
                final selected = avatarDecoration == option.$1;
                return InkWell(
                  borderRadius: BorderRadius.circular(15),
                  onTap: () => onDecoration(option.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 78,
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: selected
                          ? accent.withValues(alpha: 0.13)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(
                        color: selected
                            ? accent.withValues(alpha: 0.66)
                            : Colors.transparent,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ProfileAvatar(
                          profile: profile.copyWith(
                            avatarDecoration: option.$1,
                          ),
                          radius: 29,
                          animateDecoration: false,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          option.$2,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: selected ? Colors.white : Colors.white60,
                            fontWeight: selected
                                ? FontWeight.w800
                                : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 14),
        _StudioPanel(
          title: 'Glow and accent',
          subtitle: 'The accent is public and follows your profile.',
          icon: Icons.palette_outlined,
          child: Column(
            children: [
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: profileGlow,
                  onChanged: onGlow,
                  title: const Text('Soft avatar glow'),
                  subtitle: const Text(
                    'Adds a restrained halo to large avatars',
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: meshStudioProfileAccents.map((value) {
                    final selected = profileAccent == value;
                    final color = Color(value);
                    return Tooltip(
                      message: 'Use this public accent',
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => onAccent(value),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 39,
                          height: 39,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            border: Border.all(
                              color: selected ? Colors.white : Colors.white24,
                              width: selected ? 3 : 1,
                            ),
                            boxShadow: selected
                                ? [
                                    BoxShadow(
                                      color: color.withValues(alpha: 0.45),
                                      blurRadius: 14,
                                    ),
                                  ]
                                : null,
                          ),
                          child: selected
                              ? const Icon(Icons.check_rounded, size: 21)
                              : null,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StudioPanel extends StatelessWidget {
  const _StudioPanel({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF172331).withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFF7EDFFF), size: 21),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: child),
        ],
      ),
    );
  }
}

class _ControlLabel extends StatelessWidget {
  const _ControlLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white70,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _CompactChoice extends StatelessWidget {
  const _CompactChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.leading,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      selected: selected,
      onSelected: (_) => onTap(),
      avatar: leading ?? (icon == null ? null : Icon(icon, size: 17)),
      label: Text(label),
      showCheckmark: false,
    );
  }
}

class _StudioLocked extends StatelessWidget {
  const _StudioLocked({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: _StudioPanel(
            title: 'MeshStudio is part of MeshPro',
            subtitle:
                'Build linked profile styles with banners, frames and message effects.',
            icon: Icons.workspace_premium_rounded,
            child: FilledButton.icon(
              onPressed: () => showMeshProPaywall(
                context,
                controller,
                featureId: 'profile_background',
                featureTitle: 'MeshStudio',
                featureDescription:
                    'Create and sync a complete MeshPro appearance.',
              ),
              icon: const Icon(Icons.lock_open_rounded),
              label: const Text('Open MeshPro'),
            ),
          ),
        ),
      ),
    );
  }
}

Color _bannerBaseColor(String banner) {
  return switch (banner) {
    'aurora' => const Color(0xFF172438),
    'starlight' => const Color(0xFF11172C),
    'stardust' => const Color(0xFF090F21),
    'ember' => const Color(0xFF1A1118),
    'sunset' => const Color(0xFF151329),
    'frost' => const Color(0xFF0C1A25),
    'orbit' => const Color(0xFF0B1324),
    _ => const Color(0xFF162432),
  };
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return '${value[0].toUpperCase()}${value.substring(1)}';
}
