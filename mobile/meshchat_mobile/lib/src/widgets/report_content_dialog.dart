import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';

const _reportReasons = <(String, String)>[
  ('spam', 'Spam or scam'),
  ('harassment', 'Harassment or bullying'),
  ('hate', 'Hate or discrimination'),
  ('sexual', 'Sexual or explicit content'),
  ('violence', 'Violence or threats'),
  ('illegal', 'Illegal activity'),
  ('privacy', 'Privacy violation'),
  ('other', 'Other'),
];

Future<bool> showReportContentDialog(
  BuildContext context, {
  required AppController controller,
  required String subjectType,
  required String subjectId,
  required String title,
  String conversationId = '',
  String targetLogin = '',
  Map<String, dynamic> snapshot = const {},
}) async {
  var selectedReason = _reportReasons.first.$1;
  final detailsController = TextEditingController();
  var busy = false;
  String? error;
  final submitted = await showDialog<bool>(
    context: context,
    barrierDismissible: !busy,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        backgroundColor: const Color(0xFF151F2C),
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Reports are reviewed by the MeshChat moderation team.',
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: selectedReason,
                decoration: const InputDecoration(labelText: 'Reason'),
                items: [
                  for (final reason in _reportReasons)
                    DropdownMenuItem(value: reason.$1, child: Text(reason.$2)),
                ],
                onChanged: busy
                    ? null
                    : (value) {
                        if (value != null) selectedReason = value;
                      },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: detailsController,
                enabled: !busy,
                minLines: 2,
                maxLines: 4,
                maxLength: 1000,
                decoration: InputDecoration(
                  labelText: 'Details (optional)',
                  errorText: error,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      error = null;
                    });
                    final result = await controller.reportContent(
                      subjectType: subjectType,
                      subjectId: subjectId,
                      reason: selectedReason,
                      conversationId: conversationId,
                      targetLogin: targetLogin,
                      details: detailsController.text,
                      snapshot: snapshot,
                    );
                    if (!dialogContext.mounted) return;
                    if (result != null) {
                      setState(() {
                        busy = false;
                        error = result;
                      });
                      return;
                    }
                    Navigator.pop(dialogContext, true);
                  },
            icon: busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.flag_outlined),
            label: const Text('Submit report'),
          ),
        ],
      ),
    ),
  );
  detailsController.dispose();
  return submitted == true;
}
