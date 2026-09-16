import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'mesh_home_background.dart';

class MeshDesktopNavigation extends StatelessWidget {
  const MeshDesktopNavigation({
    super.key,
    required this.navigatorKey,
    required this.child,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!MeshDesktop.isDesktop) return child;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          navigatorKey.currentState?.maybePop();
        },
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () {
          navigatorKey.currentState?.maybePop();
        },
      },
      child: child,
    );
  }
}

abstract final class MeshDesktop {
  static bool get isDesktop => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
  static bool workspaceOf(BuildContext context) =>
      isDesktop &&
      MediaQuery.sizeOf(context).width >= MeshSurface.desktopBreakpoint;
}

abstract final class MeshSurface {
  static const canvas = Color(0xFF141719);
  static const panel = Color(0xFF1D2225);
  static const raised = Color(0xFF272D31);
  static const border = Color(0xFF394146);
  static const muted = Color(0xFFA6B1B8);
  static const desktopBreakpoint = 1000.0;
}

class MeshWorkspaceSelection extends InheritedWidget {
  const MeshWorkspaceSelection({
    super.key,
    required this.threadKey,
    required super.child,
  });
  final String? threadKey;
  static String? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MeshWorkspaceSelection>()
      ?.threadKey;
  @override
  bool updateShouldNotify(MeshWorkspaceSelection oldWidget) =>
      threadKey != oldWidget.threadKey;
}

class MeshWorkspace extends StatelessWidget {
  const MeshWorkspace({
    super.key,
    required this.sidebar,
    required this.conversation,
    this.animateBackground = true,
  });
  final Widget sidebar;
  final Widget? conversation;
  final bool animateBackground;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 320, child: sidebar),
      const VerticalDivider(width: 1, color: MeshSurface.border),
      Expanded(
        child:
            conversation ??
            Stack(
              fit: StackFit.expand,
              children: [
                MeshHomeBackground(
                  enabled:
                      animateBackground &&
                      !MediaQuery.disableAnimationsOf(context),
                ),
                const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image(
                        image: AssetImage('assets/app_icon.png'),
                        width: 72,
                        height: 72,
                      ),
                      SizedBox(height: 18),
                      Text(
                        'MeshChat',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
      ),
    ],
  );
}

/// A separate navigation stack keeps profile/media back buttons inside the pane.
class MeshDetailPane extends StatelessWidget {
  const MeshDetailPane({
    super.key,
    required this.builder,
    required this.onClose,
  });
  final WidgetBuilder builder;
  final ValueChanged<Object?> onClose;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 340,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        color: MeshSurface.panel,
        border: Border(left: BorderSide(color: MeshSurface.border)),
      ),
      child: Navigator(
        pages: [
          const MaterialPage<void>(
            key: ValueKey('pane-base'),
            child: SizedBox.shrink(),
          ),
          MaterialPage<Object?>(
            key: const ValueKey('pane-content'),
            onPopInvoked: (didPop, result) {
              if (didPop) onClose(result);
            },
            child: Builder(builder: builder),
          ),
        ],
        onDidRemovePage: (_) {},
      ),
    ),
  );
}
