import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/profile.dart';
import '../widgets/profile_avatar.dart';

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
  String avatarData = '';
  bool saving = false;

  @override
  void initState() {
    super.initState();
    final profile = widget.controller.ownProfile;
    nameInput = TextEditingController(text: profile.displayName);
    usernameInput = TextEditingController(text: profile.publicUsername);
    aboutInput = TextEditingController(text: profile.about);
    avatarData = profile.avatarData;
  }

  @override
  void dispose() {
    nameInput.dispose();
    usernameInput.dispose();
    aboutInput.dispose();
    super.dispose();
  }

  Future<void> pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.image,
    );
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    final maxSourceBytes = kIsWeb ? 2 * 1024 * 1024 : 6 * 1024 * 1024;
    if (bytes.length > maxSourceBytes) {
      if (!mounted) return;
      showSnack('Avatar image is too large');
      return;
    }
    final avatarBytes = await makeAvatarBytes(bytes);
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
    );

    return Scaffold(
      appBar: AppBar(
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        children: [
          Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ProfileAvatar(profile: preview, radius: 56),
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
          ),
          const SizedBox(height: 28),
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
          OutlinedButton.icon(
            onPressed: avatarData.isEmpty
                ? null
                : () => setState(() => avatarData = ''),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Remove avatar'),
          ),
        ],
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
