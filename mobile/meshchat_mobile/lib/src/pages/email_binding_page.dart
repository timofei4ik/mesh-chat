import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';

class EmailBindingPage extends StatefulWidget {
  const EmailBindingPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<EmailBindingPage> createState() => _EmailBindingPageState();
}

class _EmailBindingPageState extends State<EmailBindingPage> {
  final emailController = TextEditingController();
  final codeController = TextEditingController();
  String challengeId = '';
  String maskedEmail = '';
  String? error;
  bool busy = false;

  @override
  void dispose() {
    emailController.dispose();
    codeController.dispose();
    super.dispose();
  }

  Future<void> requestCode() async {
    final email = emailController.text.trim();
    if (!email.contains('@')) {
      setState(() => error = 'Enter a valid email address');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final result = await widget.controller.requestEmailBinding(email);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (result['ok'] == true) {
        challengeId = result['challenge_id']?.toString() ?? '';
        maskedEmail = result['masked_email']?.toString() ?? email;
      } else {
        error = result['message']?.toString() ?? 'Could not send the code';
      }
    });
  }

  Future<void> confirmCode() async {
    final code = codeController.text.trim();
    if (code.length != 6) {
      setState(() => error = 'Enter the 6-digit code');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final result = await widget.controller.confirmEmailBinding(
      challengeId: challengeId,
      code: code,
      email: emailController.text,
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      if (result['ok'] != true) {
        error = result['message']?.toString() ?? 'Invalid verification code';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final waitingForCode = challengeId.isNotEmpty;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF07111E),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Icon(Icons.mark_email_read_outlined, size: 56),
                        const SizedBox(height: 18),
                        Text(
                          'Protect your MeshChat account',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          waitingForCode
                              ? 'Enter the code sent to $maskedEmail.'
                              : 'Link an email for two-factor authentication and account recovery.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white60),
                        ),
                        const SizedBox(height: 24),
                        if (!waitingForCode)
                          TextField(
                            controller: emailController,
                            autofocus: true,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            onSubmitted: (_) => requestCode(),
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.mail_outline),
                            ),
                          )
                        else
                          TextField(
                            controller: codeController,
                            autofocus: true,
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            onSubmitted: (_) => confirmCode(),
                            decoration: const InputDecoration(
                              labelText: 'Verification code',
                              prefixIcon: Icon(Icons.password_outlined),
                            ),
                          ),
                        if (error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            error!,
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        ],
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: busy
                              ? null
                              : waitingForCode
                              ? confirmCode
                              : requestCode,
                          icon: busy
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  waitingForCode
                                      ? Icons.verified_outlined
                                      : Icons.send_outlined,
                                ),
                          label: Text(
                            waitingForCode ? 'Verify email' : 'Send code',
                          ),
                        ),
                        if (waitingForCode)
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                    challengeId = '';
                                    codeController.clear();
                                    error = null;
                                  }),
                            child: const Text('Use another email'),
                          ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: busy ? null : widget.controller.logout,
                          child: const Text('Sign out'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
