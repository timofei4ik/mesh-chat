import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../controllers/app_controller.dart';
import '../models/profile.dart';
import '../widgets/meshpro_badge.dart';
import '../widgets/meshpro_gate.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/profile_effect_background.dart';
import 'mesh_studio_page.dart';

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key, required this.controller});

  final AppController controller;

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController nameInput;
  late final TextEditingController usernameInput;
  late final TextEditingController aboutInput;
  late final TextEditingController emojiStatusInput;
  String avatarData = '';
  String profileBackground = Profile.defaultBackground;
  String profileEffect = Profile.defaultEffect;
  String profileBlinkShape = 'dot';
  String avatarDecoration = Profile.defaultAvatarDecoration;
  bool profileGlow = false;
  int profileAccent = Profile.defaultAccent;
  bool saving = false;

  // Kept only for migration builds; the visible editor lives in MeshStudio.
  bool get _legacyProfileControlsEnabled => false;
  static const profileAccents = <int>[
    0xFF42A5F5,
    0xFF3BD6FF,
    0xFFA56BFF,
    0xFF67F3C4,
    0xFFFF6B9C,
    0xFFFFB65C,
  ];
  static const avatarDecorations = <(String, String)>[
    ('none', 'None'),
    ('stardust', 'Stardust'),
    ('ember', 'Ember'),
    ('sunset_clouds', 'Sunset'),
    ('neon_orbit', 'Orbit'),
    ('frost_bloom', 'Frost'),
  ];
  static const appearancePresets =
      <
        ({
          String id,
          String label,
          String background,
          String effect,
          String blink,
          String decoration,
          int accent,
        })
      >[
        (
          id: 'stardust',
          label: 'Stardust',
          background: 'stardust',
          effect: 'stars',
          blink: 'star',
          decoration: 'stardust',
          accent: 0xFF75DFFF,
        ),
        (
          id: 'ember',
          label: 'Ember',
          background: 'ember',
          effect: 'nodes',
          blink: 'dot',
          decoration: 'ember',
          accent: 0xFFFF7A55,
        ),
        (
          id: 'sunset',
          label: 'Sunset',
          background: 'sunset',
          effect: 'orbit',
          blink: 'dot',
          decoration: 'sunset_clouds',
          accent: 0xFFFF79B0,
        ),
        (
          id: 'frost',
          label: 'Frost',
          background: 'frost',
          effect: 'stars',
          blink: 'star',
          decoration: 'frost_bloom',
          accent: 0xFFB9F3FF,
        ),
        (
          id: 'orbit',
          label: 'Orbit',
          background: 'orbit',
          effect: 'orbit',
          blink: 'dot',
          decoration: 'neon_orbit',
          accent: 0xFFA56BFF,
        ),
      ];
  static const profileBackgrounds = <(String, String)>[
    ('mesh', 'Mesh'),
    ('aurora', 'Aurora'),
    ('starlight', 'Starlight'),
    ('stardust', 'Stardust'),
    ('ember', 'Ember'),
    ('sunset', 'Sunset'),
    ('frost', 'Frost'),
    ('orbit', 'Orbit'),
  ];

  String get selectedPresetId {
    for (final preset in appearancePresets) {
      if (profileBackground == preset.background &&
          profileEffect == preset.effect &&
          profileBlinkShape == preset.blink &&
          avatarDecoration == preset.decoration &&
          profileAccent == preset.accent) {
        return preset.id;
      }
    }
    return '';
  }

  void applyAppearancePreset(
    ({
      String id,
      String label,
      String background,
      String effect,
      String blink,
      String decoration,
      int accent,
    })
    preset,
  ) {
    setState(() {
      profileBackground = preset.background;
      profileEffect = preset.effect;
      profileBlinkShape = preset.blink;
      avatarDecoration = preset.decoration;
      profileAccent = preset.accent;
      profileGlow = true;
    });
  }

  @override
  void initState() {
    super.initState();
    final profile = widget.controller.ownProfile;
    nameInput = TextEditingController(text: profile.displayName);
    usernameInput = TextEditingController(text: profile.publicUsername);
    aboutInput = TextEditingController(text: profile.about);
    emojiStatusInput = TextEditingController(text: profile.emojiStatus);
    avatarData = profile.avatarData;
    profileBackground = profile.effectiveProfileBanner;
    profileEffect = profile.effectiveProfileEffect;
    profileBlinkShape = profile.effectiveProfileBlinkShape;
    avatarDecoration = profile.effectiveAvatarDecoration;
    profileGlow = profile.effectiveProfileGlow;
    profileAccent = profile.effectiveProfileAccent;
  }

  @override
  void dispose() {
    nameInput.dispose();
    usernameInput.dispose();
    aboutInput.dispose();
    emojiStatusInput.dispose();
    super.dispose();
  }

  Future<void> openMeshStudio() async {
    final allowed = await requireMeshPro(
      context,
      widget.controller,
      featureId: 'profile_background',
      title: 'MeshStudio',
      description:
          'Create linked profile presets with live profile and message previews.',
    );
    if (!allowed || !mounted) return;
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MeshStudioPage(controller: widget.controller),
      ),
    );
    if (changed != true || !mounted) return;
    final profile = widget.controller.ownProfile;
    setState(() {
      profileBackground = profile.effectiveProfileBanner;
      profileEffect = profile.effectiveProfileEffect;
      profileBlinkShape = profile.effectiveProfileBlinkShape;
      avatarDecoration = profile.effectiveAvatarDecoration;
      profileGlow = profile.effectiveProfileGlow;
      profileAccent = profile.effectiveProfileAccent;
    });
  }

  Future<void> pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.image,
    );
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    if (!mounted) return;
    final extension = file.extension?.trim().toLowerCase() ?? '';
    if (extension == 'gif') {
      final allowed = await requireMeshPro(
        context,
        widget.controller,
        featureId: 'animated_avatar',
        title: 'Animated avatar',
        description: 'Use a GIF avatar that follows your MeshChat account.',
      );
      if (!allowed || !mounted) return;
      if (bytes.length > 600 * 1024) {
        showSnack('Animated avatar must be up to 600 KB');
        return;
      }
      setState(() {
        avatarData = 'data:image/gif;base64,${base64Encode(bytes)}';
      });
      return;
    }
    final maxSourceBytes = kIsWeb ? 2 * 1024 * 1024 : 6 * 1024 * 1024;
    if (bytes.length > maxSourceBytes) {
      if (!mounted) return;
      showSnack('Avatar image is too large');
      return;
    }
    if (!mounted) return;
    final cropped = await showDialog<Uint8List>(
      context: context,
      builder: (_) => _AvatarCropDialog(bytes: bytes),
    );
    if (cropped == null) return;
    final avatarBytes = await makeAvatarBytes(cropped);
    if (!mounted) return;
    if (avatarBytes.length > 96 * 1024) {
      showSnack('Avatar is too large after compression');
      return;
    }
    setState(() {
      avatarData = 'data:image/png;base64,${base64Encode(avatarBytes)}';
    });
  }

  Future<void> save() async {
    if (saving) return;
    setState(() => saving = true);
    try {
      final error = await widget.controller.updateProfile(
        displayName: nameInput.text,
        publicUsername: usernameInput.text,
        about: aboutInput.text,
        avatarData: avatarData,
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
        emojiStatus: meshProFeatureEnabled(widget.controller, 'emoji_status')
            ? emojiStatusInput.text.trim()
            : '',
      );
      if (!mounted) return;
      if (error != null) {
        showSnack(error);
        return;
      }
      showSnack('Profile updated');
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      showSnack('Profile update failed: $error');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = Profile(
      nodeId: widget.controller.myNodeId,
      displayName: nameInput.text.trim().isEmpty
          ? 'User'
          : nameInput.text.trim(),
      publicUsername: usernameInput.text.trim().replaceFirst('@', ''),
      about: aboutInput.text.trim(),
      avatarData: avatarData,
      online: true,
      meshProBadge: meshProFeatureEnabled(
        widget.controller,
        'profile_background',
      ),
      profileBackground: profileBackground,
      profileEffect: profileEffect,
      profileBlinkShape: profileBlinkShape,
      avatarDecoration: avatarDecoration,
      profileGlow: profileGlow,
      profileAccent: profileAccent,
      emojiStatus: emojiStatusInput.text.trim(),
    );
    final accent = Color(preview.effectiveProfileAccent);
    final previewColor = switch (preview.effectiveProfileBanner) {
      'aurora' => const Color(0xFF172438),
      'starlight' => const Color(0xFF11172C),
      'stardust' => const Color(0xFF090F21),
      'ember' => const Color(0xFF1A1118),
      'sunset' => const Color(0xFF151329),
      'frost' => const Color(0xFF0C1A25),
      'orbit' => const Color(0xFF0B1324),
      _ => const Color(0xFF202B36),
    };

    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Profile'),
        actions: [
          TextButton(
            onPressed: saving ? null : save,
            child: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xFF07111E)),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Container(
              decoration: BoxDecoration(
                color: previewColor,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: accent.withValues(
                    alpha: preview.effectiveProfileGlow ? 0.48 : 0.18,
                  ),
                ),
                boxShadow: preview.effectiveProfileGlow
                    ? [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.22),
                          blurRadius: 34,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: ProfileEffectBackground(
                      profile: preview,
                      enabled: meshProFeatureEnabled(
                        widget.controller,
                        'profile_effect',
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
                    child: Column(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              padding: EdgeInsets.all(
                                preview.effectiveAvatarDecoration == 'none'
                                    ? 4
                                    : 0,
                              ),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border:
                                    preview.effectiveAvatarDecoration == 'none'
                                    ? Border.all(
                                        color: accent.withValues(alpha: 0.7),
                                      )
                                    : null,
                                boxShadow: preview.effectiveProfileGlow
                                    ? [
                                        BoxShadow(
                                          color: accent.withValues(alpha: 0.4),
                                          blurRadius: 28,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: ProfileAvatar(
                                profile: preview,
                                radius: 62,
                              ),
                            ),
                            Positioned(
                              right: -4,
                              bottom: -4,
                              child: IconButton.filled(
                                tooltip: 'Choose avatar',
                                onPressed: pickAvatar,
                                icon: const Icon(Icons.photo_camera_outlined),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        MeshProProfileName(
                          profile: preview,
                          animate: true,
                          badgeSize: 18,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (preview.publicUsername.isNotEmpty)
                          Text(
                            '@${preview.publicUsername}',
                            style: const TextStyle(color: Colors.white60),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: nameInput,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: usernameInput,
              decoration: const InputDecoration(
                labelText: '@username',
                prefixIcon: Icon(Icons.alternate_email),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: aboutInput,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'About',
                prefixIcon: Icon(Icons.info_outline),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: openMeshStudio,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('Open MeshStudio'),
            ),
            const SizedBox(height: 10),
            MeshProGate(
              controller: widget.controller,
              featureId: 'emoji_status',
              title: 'Emoji status',
              description: 'Show a short emoji status beside your name.',
              child: TextField(
                controller: emojiStatusInput,
                maxLength: 8,
                decoration: const InputDecoration(
                  labelText: 'Emoji status',
                  hintText: '🎧',
                  prefixIcon: Icon(Icons.emoji_emotions_outlined),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: 16),
            if (_legacyProfileControlsEnabled)
              MeshProGate(
                controller: widget.controller,
                featureId: 'profile_background',
                title: 'MeshPro profile style',
                description:
                    'Choose a public background, avatar glow and accent color.',
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.055),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.auto_awesome_rounded,
                            color: Color(0xFFB28AFF),
                          ),
                          SizedBox(width: 10),
                          Text(
                            'MeshPro appearance',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Linked presets',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 9),
                      SizedBox(
                        height: 66,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: appearancePresets.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final preset = appearancePresets[index];
                            final selected = selectedPresetId == preset.id;
                            final color = Color(preset.accent);
                            return InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => applyAppearancePreset(preset),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: 104,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 11,
                                  vertical: 9,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  color: color.withValues(
                                    alpha: selected ? 0.20 : 0.07,
                                  ),
                                  border: Border.all(
                                    color: color.withValues(
                                      alpha: selected ? 0.75 : 0.18,
                                    ),
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      selected
                                          ? Icons.auto_awesome_rounded
                                          : Icons.auto_awesome_outlined,
                                      color: color,
                                      size: 19,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      preset.label,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: selected
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 7),
                        child: Text(
                          'A preset links the banner, frame, name glow and message effect.',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Profile banner',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 9),
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: profileBackgrounds.map((option) {
                          return ChoiceChip(
                            label: Text(option.$2),
                            selected: profileBackground == option.$1,
                            onSelected: (_) =>
                                setState(() => profileBackground = option.$1),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Animated detail',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 9),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<String>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: 'stars',
                              icon: Icon(Icons.auto_awesome_rounded),
                              label: Text('Stars'),
                            ),
                            ButtonSegment(
                              value: 'nodes',
                              icon: Icon(Icons.scatter_plot_outlined),
                              label: Text('Nodes'),
                            ),
                            ButtonSegment(
                              value: 'orbit',
                              icon: Icon(Icons.blur_circular_rounded),
                              label: Text('Orbit'),
                            ),
                          ],
                          selected: {profileEffect},
                          onSelectionChanged: (selection) =>
                              setState(() => profileEffect = selection.first),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 7),
                        child: Text(
                          'Controls what gently twinkles behind your avatar.',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Blink shape',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 9),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<String>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: 'dot',
                              icon: Icon(Icons.circle, size: 13),
                              label: Text('Dot'),
                            ),
                            ButtonSegment(
                              value: 'star',
                              icon: Icon(Icons.auto_awesome_rounded),
                              label: Text('Star'),
                            ),
                            ButtonSegment(
                              value: 'moose',
                              icon: Text(
                                '𐂂',
                                style: TextStyle(
                                  fontFamily: 'NotoSansLinearB',
                                  fontSize: 19,
                                  height: 1,
                                ),
                              ),
                              label: Text('Moose'),
                            ),
                          ],
                          selected: {profileBlinkShape},
                          onSelectionChanged: (selection) => setState(
                            () => profileBlinkShape = selection.first,
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 7),
                        child: Text(
                          'Uses a bundled symbol, so Moose renders on every device.',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Avatar frame',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 92,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: avatarDecorations.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final option = avatarDecorations[index];
                            final selected = avatarDecoration == option.$1;
                            return Tooltip(
                              message: '${option.$2} avatar frame',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () => setState(
                                  () => avatarDecoration = option.$1,
                                ),
                                child: SizedBox(
                                  width: 74,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        curve: Curves.easeOutCubic,
                                        padding: const EdgeInsets.all(3),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: selected
                                              ? accent.withValues(alpha: 0.18)
                                              : Colors.transparent,
                                          border: Border.all(
                                            color: selected
                                                ? accent.withValues(alpha: 0.8)
                                                : Colors.transparent,
                                          ),
                                        ),
                                        child: ProfileAvatar(
                                          profile: preview.copyWith(
                                            avatarDecoration: option.$1,
                                          ),
                                          radius: 27,
                                          animateDecoration: false,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        option.$2,
                                        maxLines: 1,
                                        overflow: TextOverflow.fade,
                                        softWrap: false,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: selected
                                              ? Colors.white
                                              : Colors.white60,
                                          fontWeight: selected
                                              ? FontWeight.w700
                                              : FontWeight.w500,
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
                      const Padding(
                        padding: EdgeInsets.only(top: 2, bottom: 8),
                        child: Text(
                          'Large avatars animate smoothly; compact lists use a battery-friendly still frame.',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: profileGlow,
                        onChanged: (value) =>
                            setState(() => profileGlow = value),
                        title: const Text('Avatar glow'),
                        subtitle: const Text(
                          'A soft accent halo around your avatar',
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Public accent',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 11,
                        runSpacing: 11,
                        children: profileAccents.map((value) {
                          final selected = profileAccent == value;
                          final color = Color(value);
                          return Tooltip(
                            message: 'Use this profile accent',
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () =>
                                  setState(() => profileAccent = value),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: color,
                                  border: Border.all(
                                    color: selected
                                        ? Colors.white
                                        : Colors.white24,
                                    width: selected ? 3 : 1,
                                  ),
                                  boxShadow: selected
                                      ? [
                                          BoxShadow(
                                            color: color.withValues(
                                              alpha: 0.45,
                                            ),
                                            blurRadius: 14,
                                          ),
                                        ]
                                      : null,
                                ),
                                child: selected
                                    ? const Icon(Icons.check_rounded, size: 20)
                                    : null,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: avatarData.isEmpty
                  ? null
                  : () => setState(() => avatarData = ''),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove avatar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<Uint8List> makeAvatarBytes(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 160,
      targetHeight: 160,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (byteData == null) return bytes;
    return byteData.buffer.asUint8List();
  }

  void showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

class _AvatarCropDialog extends StatefulWidget {
  const _AvatarCropDialog({required this.bytes});

  final Uint8List bytes;

  @override
  State<_AvatarCropDialog> createState() => _AvatarCropDialogState();
}

class _AvatarCropDialogState extends State<_AvatarCropDialog> {
  final repaintKey = GlobalKey();
  final transform = TransformationController();
  double zoom = 1.08;
  bool exporting = false;

  @override
  void initState() {
    super.initState();
    _applyZoom();
  }

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  void _applyZoom() {
    transform.value = Matrix4.diagonal3Values(zoom, zoom, 1);
  }

  Future<void> save() async {
    if (exporting) return;
    setState(() => exporting = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final boundary =
          repaintKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final pixelRatio = 256 / boundary.size.width;
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (!mounted || data == null) return;
      Navigator.pop(context, data.buffer.asUint8List());
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xEE16202A),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Adjust avatar',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: 260,
                    height: 260,
                    child: Stack(
                      children: [
                        RepaintBoundary(
                          key: repaintKey,
                          child: ClipOval(
                            child: SizedBox(
                              width: 260,
                              height: 260,
                              child: InteractiveViewer(
                                transformationController: transform,
                                minScale: 0.75,
                                maxScale: 4,
                                boundaryMargin: const EdgeInsets.all(140),
                                child: SizedBox(
                                  width: 320,
                                  height: 320,
                                  child: Image.memory(
                                    widget.bytes,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.lightBlueAccent.withValues(
                                  alpha: 0.75,
                                ),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.lightBlueAccent.withValues(
                                    alpha: 0.16,
                                  ),
                                  blurRadius: 22,
                                ),
                              ],
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.zoom_out_rounded),
                      Expanded(
                        child: Slider(
                          min: 0.85,
                          max: 2.6,
                          value: zoom,
                          onChanged: (value) {
                            setState(() => zoom = value);
                            _applyZoom();
                          },
                        ),
                      ),
                      const Icon(Icons.zoom_in_rounded),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          setState(() => zoom = 1.08);
                          _applyZoom();
                        },
                        child: const Text('Reset'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: exporting ? null : save,
                        child: exporting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Use avatar'),
                      ),
                    ],
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
