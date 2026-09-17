import 'package:flutter/material.dart';

import '../models/profile.dart';
import 'profile_avatar.dart';

class MessageReactionButton extends StatelessWidget {
  const MessageReactionButton({
    super.key,
    required this.icon,
    required this.reaction,
    required this.count,
    required this.selected,
    required this.profiles,
    required this.onPressed,
  });

  final Widget icon;
  final String reaction;
  final int count;
  final bool selected;
  final List<Profile> profiles;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final avatars = count <= 2
        ? profiles.take(count).toList(growable: false)
        : const <Profile>[];
    final color = selected ? const Color(0xFF183D68) : const Color(0x80132943);
    return Semantics(
      button: true,
      selected: selected,
      label: '$reaction, $count',
      child: Tooltip(
        message: selected ? 'Remove reaction' : 'Add reaction',
        child: Material(
          color: color,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected
                  ? const Color(0xFF70CFFF)
                  : const Color(0x40548ABA),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              child: SizedBox(
                height: 18,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 18,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: ExcludeSemantics(child: icon),
                      ),
                    ),
                    if (avatars.isNotEmpty) ...[
                      const SizedBox(width: 5),
                      SizedBox(
                        width: 18 + (avatars.length - 1) * 12,
                        height: 18,
                        child: Stack(
                          children: [
                            for (var i = avatars.length - 1; i >= 0; i--)
                              Positioned(
                                left: i * 12,
                                child: ProfileAvatar(
                                  profile: avatars[i],
                                  radius: 9,
                                  fillPortrait: true,
                                  animateDecoration: false,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    if (count > avatars.length || avatars.isEmpty) ...[
                      const SizedBox(width: 5),
                      SizedBox(
                        height: 18,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '$count',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFE3F3FF),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
