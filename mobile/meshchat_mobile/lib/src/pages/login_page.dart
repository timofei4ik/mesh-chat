import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../widgets/mesh_frame_clock.dart';
import '../widgets/mesh_painting.dart';

import '../controllers/app_controller.dart';
import '../models/session.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final serverController = TextEditingController(
    text: 'wss://meshchat-losa.ru/ws',
  );
  final tokenController = TextEditingController();
  final loginController = TextEditingController();
  final usernameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool obscurePassword = true;

  @override
  void dispose() {
    serverController.dispose();
    tokenController.dispose();
    loginController.dispose();
    usernameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final login = loginController.text.trim();
    final password = passwordController.text;
    if (serverController.text.trim().isEmpty ||
        login.isEmpty ||
        password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter server, login and password')),
      );
      return;
    }

    final success = await widget.controller.login(
      serverUrl: serverController.text,
      token: tokenController.text,
      login: login,
      password: password,
      publicUsername: usernameController.text.trim().isEmpty
          ? login
          : usernameController.text,
      email: emailController.text,
    );
    if (!success &&
        mounted &&
        widget.controller.pendingEmailChallengeId.isNotEmpty) {
      final code = await _showEmailCodeDialog(
        widget.controller.pendingEmailMasked,
      );
      if (code == null || !mounted) return;
      final verified = await widget.controller.login(
        serverUrl: serverController.text,
        token: tokenController.text,
        login: login,
        password: password,
        publicUsername: usernameController.text.trim().isEmpty
            ? login
            : usernameController.text,
        email: emailController.text,
        emailChallengeId: widget.controller.pendingEmailChallengeId,
        emailCode: code,
      );
      if (verified || !mounted) return;
    }
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.controller.error ?? 'Login failed'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> quickLogin(Session session) async {
    final success = await widget.controller.quickLogin(session);
    if (!success &&
        mounted &&
        widget.controller.pendingEmailChallengeId.isNotEmpty) {
      final code = await _showEmailCodeDialog(
        widget.controller.pendingEmailMasked,
      );
      if (code == null || !mounted) return;
      final verified = await widget.controller.login(
        serverUrl: session.serverUrl,
        token: session.serverToken,
        login: session.login,
        password: session.password,
        publicUsername: session.publicUsername,
        email: session.email,
        emailChallengeId: widget.controller.pendingEmailChallengeId,
        emailCode: code,
      );
      if (verified || !mounted) return;
    }
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.controller.error ?? 'Login failed'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  void fillFromRecent(Session session) {
    serverController.text = session.serverUrl;
    tokenController.text = session.serverToken;
    loginController.text = session.login;
    usernameController.text = session.publicUsername;
    passwordController.text = session.password;
    emailController.text = session.email;
  }

  Future<String?> _showEmailCodeDialog(String maskedEmail) async {
    final codeController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Check your email'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Enter the 6-digit code sent to $maskedEmail.'),
            const SizedBox(height: 16),
            TextField(
              controller: codeController,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textInputAction: TextInputAction.done,
              onSubmitted: (value) {
                if (value.trim().length == 6) {
                  Navigator.pop(context, value.trim());
                }
              },
              decoration: const InputDecoration(
                labelText: 'Verification code',
                prefixIcon: Icon(Icons.password_outlined),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = codeController.text.trim();
              if (value.length == 6) Navigator.pop(context, value);
            },
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    codeController.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07111E),
      body: Stack(
        children: [
          const Positioned.fill(child: _LoginGlowBackground()),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Image.asset(
                          'assets/app_icon.png',
                          width: 76,
                          height: 76,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'MeshChat',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Login or create account',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(color: Colors.white60),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: serverController,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Server',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: tokenController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Invite token',
                          prefixIcon: Icon(Icons.key_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: loginController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Login',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: usernameController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '@username',
                          prefixIcon: Icon(Icons.alternate_email),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: emailController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          helperText:
                              'Required for new accounts and new-device verification',
                          prefixIcon: Icon(Icons.mail_outline),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: passwordController,
                        obscureText: obscurePassword,
                        onSubmitted: (_) => submit(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: obscurePassword
                                ? 'Show password'
                                : 'Hide password',
                            onPressed: () => setState(
                              () => obscurePassword = !obscurePassword,
                            ),
                            icon: Icon(
                              obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: widget.controller.busy ? null : submit,
                        icon: widget.controller.busy
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.login),
                        label: Text(
                          widget.controller.busy
                              ? 'Connecting...'
                              : 'Login / register',
                        ),
                      ),
                      if (widget.controller.recentSessions.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        Text(
                          'Recent accounts',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        for (final recent in widget.controller.recentSessions)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Card(
                              child: ListTile(
                                leading: const CircleAvatar(
                                  child: Icon(Icons.person_outline),
                                ),
                                title: Text(recent.login),
                                subtitle: Text(
                                  recent.serverUrl,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: widget.controller.busy
                                    ? null
                                    : () => quickLogin(recent),
                                trailing: Wrap(
                                  spacing: 4,
                                  children: [
                                    IconButton(
                                      tooltip: 'Fill form',
                                      onPressed: widget.controller.busy
                                          ? null
                                          : () => fillFromRecent(recent),
                                      icon: const Icon(Icons.edit_outlined),
                                    ),
                                    IconButton(
                                      tooltip: 'Forget',
                                      onPressed: widget.controller.busy
                                          ? null
                                          : () => widget.controller
                                                .forgetRecent(recent),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
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
        ],
      ),
    );
  }
}

class _LoginGlowBackground extends StatefulWidget {
  const _LoginGlowBackground();

  @override
  State<_LoginGlowBackground> createState() => _LoginGlowBackgroundState();
}

class _LoginGlowBackgroundState extends State<_LoginGlowBackground>
    with WidgetsBindingObserver {
  late final MeshFrameClock controller;
  bool appActive = true;
  bool tickerModeActive = true;

  bool get canAnimate => appActive && tickerModeActive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = MeshFrameClock(
      duration: const Duration(seconds: 18),
      frameInterval: const Duration(milliseconds: 66),
    )..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = TickerMode.valuesOf(context).enabled;
    if (tickerModeActive == next) return;
    tickerModeActive = next;
    _syncAnimationActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appActive = state == AppLifecycleState.resumed;
    _syncAnimationActivity();
  }

  void _syncAnimationActivity() {
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

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return CustomPaint(
            isComplex: true,
            willChange: controller.isAnimating,
            painter: _LoginGlowPainter(controller.value),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _LoginGlowPainter extends CustomPainter {
  const _LoginGlowPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF081320), Color(0xFF050A12)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bg);

    void sphere({
      required Offset base,
      required double radius,
      required Color color,
      required double phase,
      required double alpha,
    }) {
      final p = t * math.pi * 2 + phase;
      final center = Offset(
        base.dx + math.cos(p) * radius * 0.12,
        base.dy + math.sin(p * 0.82) * radius * 0.10,
      );
      final pulse = 0.72 + math.sin(p * 1.3) * 0.18;
      drawRadialGlow(
        canvas,
        center: center,
        radius: radius * 1.55,
        color: color,
        opacity: alpha * pulse,
      );
      drawRadialGlow(
        canvas,
        center: center,
        radius: radius * 0.55,
        color: color,
        opacity: alpha * 0.62 * pulse,
      );
    }

    sphere(
      base: Offset(size.width * 0.12, size.height * 0.18),
      radius: size.shortestSide * 0.42,
      color: const Color(0xFF38D5FF),
      phase: 0.2,
      alpha: 0.24,
    );
    sphere(
      base: Offset(size.width * 0.88, size.height * 0.28),
      radius: size.shortestSide * 0.46,
      color: const Color(0xFFA56CFF),
      phase: 2.1,
      alpha: 0.22,
    );
    sphere(
      base: Offset(size.width * 0.52, size.height * 0.92),
      radius: size.shortestSide * 0.55,
      color: const Color(0xFF315DFF),
      phase: 4.2,
      alpha: 0.12,
    );

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = const Color(0xFF020610).withValues(alpha: 0.22)
        ..blendMode = BlendMode.srcOver,
    );
  }

  @override
  bool shouldRepaint(covariant _LoginGlowPainter oldDelegate) =>
      oldDelegate.t != t;
}
