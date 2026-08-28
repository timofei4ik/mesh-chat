class PollItem {
  const PollItem({
    required this.id,
    required this.messageId,
    required this.groupId,
    required this.creatorLogin,
    required this.question,
    required this.options,
    required this.counts,
    required this.selectedOptions,
    required this.voterCount,
    required this.isQuiz,
    required this.allowsMultiple,
    required this.isAnonymous,
    required this.isClosed,
    this.correctOption,
    this.explanation = '',
  });

  final String id;
  final String messageId;
  final String groupId;
  final String creatorLogin;
  final String question;
  final List<String> options;
  final List<int> counts;
  final Set<int> selectedOptions;
  final int voterCount;
  final bool isQuiz;
  final int? correctOption;
  final String explanation;
  final bool allowsMultiple;
  final bool isAnonymous;
  final bool isClosed;

  factory PollItem.fromJson(Map<String, dynamic> json) {
    final options =
        (json['options'] is List ? json['options'] as List : const [])
            .map((value) => value.toString())
            .toList(growable: false);
    final rawCounts = json['counts'] is List
        ? json['counts'] as List
        : const [];
    final counts = List<int>.generate(
      options.length,
      (index) => index < rawCounts.length
          ? int.tryParse(rawCounts[index].toString()) ?? 0
          : 0,
      growable: false,
    );
    final selected =
        (json['selected_options'] is List
                ? json['selected_options'] as List
                : const [])
            .map((value) => int.tryParse(value.toString()))
            .whereType<int>()
            .where((value) => value >= 0 && value < options.length)
            .toSet();
    final correct = int.tryParse(json['correct_option']?.toString() ?? '');
    return PollItem(
      id: json['poll_id']?.toString() ?? '',
      messageId: json['message_id']?.toString() ?? '',
      groupId: json['group_id']?.toString() ?? '',
      creatorLogin: json['creator_login']?.toString() ?? '',
      question: json['question']?.toString() ?? '',
      options: options,
      counts: counts,
      selectedOptions: selected,
      voterCount: int.tryParse(json['voter_count']?.toString() ?? '') ?? 0,
      isQuiz: json['is_quiz'] == true,
      correctOption: correct != null && correct >= 0 ? correct : null,
      explanation: json['explanation']?.toString() ?? '',
      allowsMultiple: json['allows_multiple'] == true,
      isAnonymous: json['is_anonymous'] != false,
      isClosed: json['is_closed'] == true,
    );
  }
}
