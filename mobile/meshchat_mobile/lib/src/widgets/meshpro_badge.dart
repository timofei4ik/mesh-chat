import 'package:flutter/material.dart';

import '../models/profile.dart';
import 'mesh_frame_clock.dart';

class MeshProBadge extends StatelessWidget {
  const MeshProBadge({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'MeshPro',
      child: SizedBox.square(
        dimension: size,
        child: ClipOval(
          child: Image.asset(
            'assets/meshpro_badge.png',
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}

class MeshProProfileName extends StatelessWidget {
  const MeshProProfileName({
    super.key,
    required this.profile,
    this.style,
    this.badgeSize = 18,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
    this.animate = false,
  });

  final Profile profile;
  final TextStyle? style;
  final double badgeSize;
  final int maxLines;
  final TextOverflow overflow;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    if (animate && profile.meshProBadge == true) {
      return _AnimatedProfileName(
        profile: profile,
        style: style,
        badgeSize: badgeSize,
        maxLines: maxLines,
        overflow: overflow,
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: profile.displayName),
          if (profile.meshProBadge == true)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(left: 5),
                child: MeshProBadge(size: badgeSize),
              ),
            ),
          if (profile.emojiStatus.trim().isNotEmpty)
            TextSpan(text: '  ${profile.emojiStatus.trim()}'),
        ],
      ),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

class _AnimatedProfileName extends StatefulWidget {
  const _AnimatedProfileName({
    required this.profile,
    required this.style,
    required this.badgeSize,
    required this.maxLines,
    required this.overflow,
  });

  final Profile profile;
  final TextStyle? style;
  final double badgeSize;
  final int maxLines;
  final TextOverflow overflow;

  @override
  State<_AnimatedProfileName> createState() => _AnimatedProfileNameState();
}

class _AnimatedProfileNameState extends State<_AnimatedProfileName>
    with WidgetsBindingObserver {
  late final MeshFrameClock controller = MeshFrameClock(
    duration: const Duration(seconds: 8),
    frameInterval: const Duration(milliseconds: 66),
  )..repeat();
  AppLifecycleState lifecycleState = AppLifecycleState.resumed;
  bool tickerEnabled = true;

  bool get canAnimate =>
      lifecycleState == AppLifecycleState.resumed && tickerEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (tickerEnabled == enabled) return;
    tickerEnabled = enabled;
    _syncAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    lifecycleState = state;
    _syncAnimation();
  }

  void _syncAnimation() {
    if (canAnimate) {
      if (!controller.isAnimating) controller.repeat();
    } else {
      controller.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  List<Color> get colors => switch (widget.profile.effectiveNameEffect) {
    'ember' => const [Color(0xFFFFC06A), Color(0xFFFF6B55), Color(0xFFFFB35C)],
    'sunset' => const [Color(0xFFFF93C9), Color(0xFFA56BFF), Color(0xFF7ADFFF)],
    'frost' => const [Color(0xFFE4FBFF), Color(0xFF70D8FF), Color(0xFFB9F3FF)],
    'orbit' => const [Color(0xFF42D9FF), Color(0xFFA56BFF), Color(0xFF42D9FF)],
    _ => const [Color(0xFFFFFFFF), Color(0xFF9BE8FF), Color(0xFFFFFFFF)],
  };

  @override
  Widget build(BuildContext context) {
    final accent = Color(widget.profile.effectiveProfileAccent);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final shift = controller.value * 1.8 - 0.9;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment(-1.4 + shift, 0),
                  end: Alignment(0.4 + shift, 0),
                  colors: colors,
                  stops: const [0, 0.5, 1],
                ).createShader(bounds),
                child: Text(
                  widget.profile.displayName,
                  style: (widget.style ?? DefaultTextStyle.of(context).style)
                      .copyWith(
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            color: accent.withValues(alpha: 0.22),
                            blurRadius: 9,
                          ),
                        ],
                      ),
                  maxLines: widget.maxLines,
                  overflow: widget.overflow,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 5),
              child: MeshProBadge(size: widget.badgeSize),
            ),
            if (widget.profile.emojiStatus.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 7),
                child: Text(
                  widget.profile.emojiStatus.trim(),
                  style: widget.style,
                ),
              ),
          ],
        );
      },
    );
  }
}
