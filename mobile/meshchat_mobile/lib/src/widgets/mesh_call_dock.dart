import 'package:flutter/material.dart';
import '../models/profile.dart';
import 'profile_avatar.dart';
import 'mesh_workspace.dart';

class MeshCallDock extends StatelessWidget {
  const MeshCallDock({
    super.key,
    required this.profile,
    required this.status,
    required this.muted,
    required this.onExpand,
    required this.onMute,
    required this.onEnd,
    this.onAccept,
    this.onCaptions,
    this.onParticipants,
  });
  final Profile profile;
  final String status;
  final bool muted;
  final VoidCallback onExpand;
  final VoidCallback onMute;
  final VoidCallback onEnd;
  final VoidCallback? onAccept;
  final VoidCallback? onCaptions;
  final VoidCallback? onParticipants;
  @override
  Widget build(BuildContext context) => Material(
    color: MeshSurface.panel,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          ProfileAvatar(profile: profile, radius: 16),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: onExpand,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      profile.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF86D7B4),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (onAccept != null)
            IconButton(
              tooltip: 'Accept',
              onPressed: onAccept,
              icon: const Icon(Icons.call, color: Color(0xFF86D7B4)),
            )
          else
            IconButton(
              tooltip: muted ? 'Unmute' : 'Mute',
              onPressed: onMute,
              icon: Icon(muted ? Icons.mic_off_outlined : Icons.mic_none),
            ),
          IconButton(
            tooltip: 'Show call',
            onPressed: onExpand,
            icon: const Icon(Icons.open_in_full, size: 18),
          ),
          if (onCaptions != null || onParticipants != null)
            PopupMenuButton<String>(
              tooltip: 'Call details',
              icon: const Icon(Icons.more_horiz),
              onSelected: (value) => value == 'captions'
                  ? onCaptions?.call()
                  : onParticipants?.call(),
              itemBuilder: (_) => [
                if (onCaptions != null)
                  const PopupMenuItem(
                    value: 'captions',
                    child: Text('Captions'),
                  ),
                if (onParticipants != null)
                  const PopupMenuItem(
                    value: 'participants',
                    child: Text('Participants'),
                  ),
              ],
            ),
          IconButton(
            tooltip: onAccept == null ? 'End' : 'Decline',
            onPressed: onEnd,
            icon: const Icon(Icons.call_end, color: Color(0xFFFF8493)),
          ),
        ],
      ),
    ),
  );
}
