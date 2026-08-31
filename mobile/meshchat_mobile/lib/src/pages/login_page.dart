import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/mesh_frame_clock.dart';
import '../widgets/mesh_painting.dart';

import '../controllers/app_controller.dart';
import '../models/session.dart';

enum _AuthenticationMode { login, registration }

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const _legalBaseUrl = 'https://meshchat-losa.ru/meshpro/legal';
  static const _acceptedRulesKey = 'accepted_rules_2026_08_18';
  final serverController = TextEditingController(
    text: 'wss://meshchat-losa.ru/ws',
  );
  final tokenController = TextEditingController();
  final loginController = TextEditingController();
  final usernameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final codeController = TextEditingController();
  _AuthenticationMode mode = _AuthenticationMode.login;
  bool obscurePassword = true;
  bool acceptedRules = false;

  @override
  void initState() {
    super.initState();
    _restoreRulesAcceptance();
    final pending = widget.controller.pendingAuthenticationSession;
    if (pending != null) {
      mode = widget.controller.pendingAuthenticationRegistration
          ? _AuthenticationMode.registration
          : _AuthenticationMode.login;
      fillFromRecent(pending);
    }
  }

  Future<void> _restoreRulesAcceptance() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      acceptedRules = preferences.getBool(_acceptedRulesKey) ?? false;
    });
  }

  Future<void> _rememberRulesAcceptance() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_acceptedRulesKey, true);
  }

  Future<void> _openLegalPage(String page) async {
    await launchUrl(
      Uri.parse('$_legalBaseUrl/$page'),
      mode: LaunchMode.externalApplication,
    );
  }

  bool _ensureRulesAccepted() {
    if (acceptedRules) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Accept the Terms and Community Guidelines to continue'),
      ),
    );
    return false;
  }

  @override
  void dispose() {
    serverController.dispose();
    tokenController.dispose();
    loginController.dispose();
    usernameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    codeController.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final registering = mode == _AuthenticationMode.registration;
    if (registering && !_ensureRulesAccepted()) return;
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

    if (registering && emailController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an email for account recovery')),
      );
      return;
    }

    if (registering) await _rememberRulesAcceptance();

    final success = await widget.controller.login(
      serverUrl: serverController.text,
      token: tokenController.text,
      login: login,
      password: password,
      publicUsername: usernameController.text.trim().isEmpty
          ? login
          : usernameController.text,
      email: registering
          ? emailController.text
          : (login.contains('@') ? login : ''),
      register: registering,
    );
    if (mounted) setState(() {});
    if (!success &&
        mounted &&
        widget.controller.pendingEmailChallengeId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.controller.error ?? 'Login failed'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> quickLogin(Session session) async {
    mode = _AuthenticationMode.login;
    fillFromRecent(session);
    final success = await widget.controller.quickLogin(session);
    if (mounted) setState(() {});
    if (!success &&
        mounted &&
        widget.controller.pendingEmailChallengeId.isEmpty) {
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

  Future<void> verifyCode() async {
    final code = codeController.text.trim();
    if (code.length != 6) return;
    final success = await widget.controller.confirmPendingAuthentication(code);
    if (!mounted) return;
    setState(() {});
    if (!success) _showError();
  }

  Future<void> resendCode() async {
    final resendAt = widget.controller.pendingEmailResendAt;
    final remaining = resendAt?.difference(DateTime.now().toUtc());
    if (remaining != null && !remaining.isNegative) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Try again in ${remaining.inSeconds + 1}s')),
      );
      return;
    }
    await widget.controller.resendPendingAuthentication();
    if (!mounted) return;
    setState(() {});
    if (widget.controller.error != null &&
        widget.controller.pendingEmailChallengeId.isEmpty) {
      _showError();
    }
  }

  void _showError() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(widget.controller.error ?? 'Authentication failed'),
        backgroundColor: Colors.red.shade700,
      ),
    );
  }

  Future<void> changeMode(_AuthenticationMode next) async {
    if (mode == next) return;
    if (widget.controller.pendingEmailChallengeId.isNotEmpty) {
      await widget.controller.cancelPendingAuthentication();
      codeController.clear();
    }
    if (!mounted) return;
    setState(() => mode = next);
  }

  Widget _buildVerificationPanel(BuildContext context) {
    final masked = widget.controller.pendingEmailMasked;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.mark_email_read_outlined, size: 42),
            const SizedBox(height: 12),
            Text(
              'Check your email',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              masked.isEmpty
                  ? 'Enter the 6-digit verification code.'
                  : 'Enter the 6-digit code sent to $masked.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            TextField(
              controller: codeController,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => verifyCode(),
              decoration: const InputDecoration(
                labelText: 'Verification code',
                prefixIcon: Icon(Icons.password_outlined),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed:
                  widget.controller.busy ||
                      codeController.text.trim().length != 6
                  ? null
                  : verifyCode,
              icon: widget.controller.busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: const Text('Verify'),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: widget.controller.busy
                      ? null
                      : () async {
                          await widget.controller.cancelPendingAuthentication();
                          if (mounted) setState(codeController.clear);
                        },
                  child: const Text('Back'),
                ),
                TextButton.icon(
                  onPressed: widget.controller.busy ? null : resendCode,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Send again'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'You can leave MeshChat to read the email. This screen will be restored when you return.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ],
        ),
      ),
    );
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
                        mode == _AuthenticationMode.login
                            ? 'Welcome back'
                            : 'Create your MeshChat account',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(color: Colors.white60),
                      ),
                      const SizedBox(height: 20),
                      SegmentedButton<_AuthenticationMode>(
                        segments: const [
                          ButtonSegment(
                            value: _AuthenticationMode.login,
                            icon: Icon(Icons.login),
                            label: Text('Login'),
                          ),
                          ButtonSegment(
                            value: _AuthenticationMode.registration,
                            icon: Icon(Icons.person_add_alt_1),
                            label: Text('Register'),
                          ),
                        ],
                        selected: {mode},
                        onSelectionChanged: widget.controller.busy
                            ? null
                            : (selection) => changeMode(selection.single),
                        showSelectedIcon: false,
                      ),
                      const SizedBox(height: 24),
                      if (widget.controller.pendingEmailChallengeId.isNotEmpty)
                        _buildVerificationPanel(context)
                      else ...[
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
                          decoration: InputDecoration(
                            labelText: mode == _AuthenticationMode.login
                                ? 'Login, @username or email'
                                : 'Login',
                            prefixIcon: const Icon(Icons.person_outline),
                          ),
                        ),
                        if (mode == _AuthenticationMode.registration) ...[
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
                        ],
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
                        if (mode == _AuthenticationMode.registration) ...[
                          const SizedBox(height: 12),
                          CheckboxListTile(
                            value: acceptedRules,
                            onChanged: widget.controller.busy
                                ? null
                                : (value) => setState(
                                    () => acceptedRules = value ?? false,
                                  ),
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: const Text('I agree to the rules'),
                            subtitle: Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                const Text('I accept the '),
                                TextButton(
                                  onPressed: () => _openLegalPage('terms'),
                                  child: const Text('Terms'),
                                ),
                                const Text(' and '),
                                TextButton(
                                  onPressed: () => _openLegalPage('community'),
                                  child: const Text('Community Guidelines'),
                                ),
                                const Text('.'),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed:
                              widget.controller.busy ||
                                  (mode == _AuthenticationMode.registration &&
                                      !acceptedRules)
                              ? null
                              : submit,
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
                                : mode == _AuthenticationMode.login
                                ? 'Login'
                                : 'Create account',
                          ),
                        ),
                      ],
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
