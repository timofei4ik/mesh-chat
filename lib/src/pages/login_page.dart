import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../models/session.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final serverController = TextEditingController(text: 'ws://31.44.7.167:8765');
  final tokenController = TextEditingController();
  final loginController = TextEditingController();
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  bool obscurePassword = true;

  @override
  void dispose() {
    serverController.dispose();
    tokenController.dispose();
    loginController.dispose();
    usernameController.dispose();
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
    );
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
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
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
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
                    onChanged: (value) {
                      if (usernameController.text.isEmpty) {
                        usernameController.text = value;
                      }
                    },
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
                        onPressed: () =>
                            setState(() => obscurePassword = !obscurePassword),
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
                            child: CircularProgressIndicator(strokeWidth: 2),
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
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
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
                                      : () => widget.controller.forgetRecent(
                                          recent,
                                        ),
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
    );
  }
}
