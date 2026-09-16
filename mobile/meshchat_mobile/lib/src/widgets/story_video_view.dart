import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Fits the entire video inside the story viewport without cropping/stretching.
class StoryVideoView extends StatefulWidget {
  const StoryVideoView({super.key, required this.controller});

  final VideoPlayerController controller;

  @override
  State<StoryVideoView> createState() => _StoryVideoViewState();
}

class _StoryVideoViewState extends State<StoryVideoView> {
  late (bool, bool, bool, Size) _displayState;

  (bool, bool, bool, Size) get _currentState {
    final value = widget.controller.value;
    return (value.isInitialized, value.isBuffering, value.hasError, value.size);
  }

  @override
  void initState() {
    super.initState();
    _displayState = _currentState;
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant StoryVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      _displayState = _currentState;
    }
  }

  void _onChanged() {
    final next = _currentState;
    // Position updates must not rebuild the story on every playback tick.
    if (next != _displayState) setState(() => _displayState = next);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (initialized, buffering, failed, size) = _displayState;
    if (failed) {
      return const Center(child: Text('Unable to play this video'));
    }
    if (!initialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: VideoPlayer(widget.controller),
              ),
            ),
          ),
          if (buffering) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
