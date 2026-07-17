class ScheduledMessageItem {
  const ScheduledMessageItem({
    required this.id,
    required this.chatKey,
    required this.preview,
    required this.nextRunAt,
    this.repeatInterval = 'none',
    this.runCount = 0,
  });

  final String id;
  final String chatKey;
  final String preview;
  final DateTime nextRunAt;
  final String repeatInterval;
  final int runCount;

  bool get repeats => repeatInterval != 'none';

  factory ScheduledMessageItem.fromJson(Map<String, dynamic> json) {
    final parsed = DateTime.tryParse(json['next_run_at']?.toString() ?? '');
    return ScheduledMessageItem(
      id: json['schedule_id']?.toString() ?? '',
      chatKey: json['chat_key']?.toString() ?? '',
      preview: json['preview']?.toString() ?? 'Scheduled message',
      nextRunAt: (parsed ?? DateTime.now()).toLocal(),
      repeatInterval: json['repeat_interval']?.toString() ?? 'none',
      runCount: int.tryParse(json['run_count']?.toString() ?? '') ?? 0,
    );
  }
}
