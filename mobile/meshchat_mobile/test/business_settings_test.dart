import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/models/business_settings.dart';

void main() {
  test('business settings normalize persisted values', () {
    final settings = BusinessSettings.fromJson({
      'enabled': true,
      'workdays': [1, 2, 2, 9],
      'quick_replies': [
        {'shortcut': 'hello', 'text': 'Hello there'},
        {'shortcut': 'hello', 'text': 'Duplicate'},
        {'shortcut': '', 'text': 'Invalid'},
      ],
    });

    expect(settings.enabled, isTrue);
    expect(settings.workdays, [1, 2]);
    expect(settings.quickReplies, hasLength(1));
    expect(settings.greetingText, 'Hello! Thanks for your message.');
  });

  test('overnight working hours cross midnight safely', () {
    const settings = BusinessSettings(
      workdays: [1],
      workdayStartMinutes: 22 * 60,
      workdayEndMinutes: 6 * 60,
    );

    expect(settings.isWithinWorkingHours(DateTime(2026, 8, 17, 23)), isTrue);
    expect(settings.isWithinWorkingHours(DateTime(2026, 8, 17, 12)), isFalse);
  });
}
