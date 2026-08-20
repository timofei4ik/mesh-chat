class BusinessQuickReply {
  const BusinessQuickReply({required this.shortcut, required this.text});

  final String shortcut;
  final String text;

  factory BusinessQuickReply.fromJson(Object? raw) {
    if (raw is! Map) return const BusinessQuickReply(shortcut: '', text: '');
    return BusinessQuickReply(
      shortcut: raw['shortcut']?.toString().trim() ?? '',
      text: raw['text']?.toString().trim() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'shortcut': shortcut, 'text': text};
}

class BusinessSettings {
  const BusinessSettings({
    this.enabled = false,
    this.greetingEnabled = false,
    this.greetingText = 'Hello! Thanks for your message.',
    this.awayEnabled = false,
    this.awayText = 'I am away right now and will reply during working hours.',
    this.workdayStartMinutes = 9 * 60,
    this.workdayEndMinutes = 18 * 60,
    this.workdays = const [1, 2, 3, 4, 5],
    this.quickReplies = const [],
  });

  final bool enabled;
  final bool greetingEnabled;
  final String greetingText;
  final bool awayEnabled;
  final String awayText;
  final int workdayStartMinutes;
  final int workdayEndMinutes;
  final List<int> workdays;
  final List<BusinessQuickReply> quickReplies;

  bool get hasQuickReplies => enabled && quickReplies.isNotEmpty;

  bool isWithinWorkingHours(DateTime localTime) {
    if (!workdays.contains(localTime.weekday)) return false;
    final minute = localTime.hour * 60 + localTime.minute;
    if (workdayStartMinutes == workdayEndMinutes) return true;
    if (workdayStartMinutes < workdayEndMinutes) {
      return minute >= workdayStartMinutes && minute < workdayEndMinutes;
    }
    return minute >= workdayStartMinutes || minute < workdayEndMinutes;
  }

  BusinessSettings copyWith({
    bool? enabled,
    bool? greetingEnabled,
    String? greetingText,
    bool? awayEnabled,
    String? awayText,
    int? workdayStartMinutes,
    int? workdayEndMinutes,
    List<int>? workdays,
    List<BusinessQuickReply>? quickReplies,
  }) {
    return BusinessSettings(
      enabled: enabled ?? this.enabled,
      greetingEnabled: greetingEnabled ?? this.greetingEnabled,
      greetingText: greetingText ?? this.greetingText,
      awayEnabled: awayEnabled ?? this.awayEnabled,
      awayText: awayText ?? this.awayText,
      workdayStartMinutes: workdayStartMinutes ?? this.workdayStartMinutes,
      workdayEndMinutes: workdayEndMinutes ?? this.workdayEndMinutes,
      workdays: workdays ?? this.workdays,
      quickReplies: quickReplies ?? this.quickReplies,
    );
  }

  factory BusinessSettings.fromJson(Object? raw) {
    if (raw is! Map) return const BusinessSettings();
    final replies = <BusinessQuickReply>[];
    final rawReplies = raw['quick_replies'];
    if (rawReplies is List) {
      for (final item in rawReplies) {
        final reply = BusinessQuickReply.fromJson(item);
        if (reply.shortcut.isEmpty || reply.text.isEmpty) continue;
        if (replies.any((existing) => existing.shortcut == reply.shortcut)) {
          continue;
        }
        replies.add(reply);
        if (replies.length >= 20) break;
      }
    }
    final days = <int>[];
    final rawDays = raw['workdays'];
    if (rawDays is List) {
      for (final item in rawDays) {
        final day = int.tryParse(item.toString());
        if (day != null && day >= 1 && day <= 7 && !days.contains(day)) {
          days.add(day);
        }
      }
    }
    return BusinessSettings(
      enabled: raw['enabled'] == true,
      greetingEnabled: raw['greeting_enabled'] == true,
      greetingText: _text(
        raw['greeting_text'],
        500,
        'Hello! Thanks for your message.',
      ),
      awayEnabled: raw['away_enabled'] == true,
      awayText: _text(
        raw['away_text'],
        500,
        'I am away right now and will reply during working hours.',
      ),
      workdayStartMinutes: _minutes(raw['workday_start_minutes'], 9 * 60),
      workdayEndMinutes: _minutes(raw['workday_end_minutes'], 18 * 60),
      workdays: days.isEmpty ? const [1, 2, 3, 4, 5] : days,
      quickReplies: replies,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'greeting_enabled': greetingEnabled,
    'greeting_text': greetingText,
    'away_enabled': awayEnabled,
    'away_text': awayText,
    'workday_start_minutes': workdayStartMinutes,
    'workday_end_minutes': workdayEndMinutes,
    'workdays': workdays,
    'quick_replies': quickReplies.map((item) => item.toJson()).toList(),
  };

  static String _text(Object? raw, int limit, String fallback) {
    final value = raw?.toString().trim() ?? '';
    final normalized = value.isEmpty ? fallback : value;
    return normalized.length <= limit
        ? normalized
        : normalized.substring(0, limit);
  }

  static int _minutes(Object? raw, int fallback) {
    final value = int.tryParse(raw?.toString() ?? '');
    return value == null ? fallback : value.clamp(0, 1439);
  }
}
