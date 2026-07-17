class MeshProSubscription {
  const MeshProSubscription({
    required this.active,
    required this.status,
    required this.planCode,
    this.periodEnd,
    this.cancelAtPeriodEnd = false,
    this.entitlements = const MeshProEntitlements.empty(),
  });

  const MeshProSubscription.inactive()
    : active = false,
      status = 'inactive',
      planCode = 'none',
      periodEnd = null,
      cancelAtPeriodEnd = false,
      entitlements = const MeshProEntitlements.empty();

  factory MeshProSubscription.fromJson(Object? value) {
    if (value is! Map) return const MeshProSubscription.inactive();
    final json = Map<String, dynamic>.from(value);
    final active = json['active'] == true;
    return MeshProSubscription(
      active: active,
      status: json['status']?.toString() ?? 'inactive',
      planCode: json['plan_code']?.toString() ?? 'none',
      periodEnd: _parseServerTime(json['current_period_end']?.toString()),
      cancelAtPeriodEnd: json['cancel_at_period_end'] == true,
      entitlements: MeshProEntitlements.fromJson(
        json['entitlements'],
        legacyActive: active,
      ),
    );
  }

  final bool active;
  final String status;
  final String planCode;
  final DateTime? periodEnd;
  final bool cancelAtPeriodEnd;
  final MeshProEntitlements entitlements;

  bool get isActiveNow {
    final end = periodEnd;
    return active && (end == null || end.isAfter(DateTime.now()));
  }

  Duration get remaining {
    final end = periodEnd;
    if (!isActiveNow || end == null) return Duration.zero;
    return end.difference(DateTime.now());
  }

  static DateTime? _parseServerTime(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    var normalized = value.trim().replaceFirst(' ', 'T');
    final hasZone =
        normalized.endsWith('Z') ||
        RegExp(r'[+-]\d\d:\d\d$').hasMatch(normalized);
    if (!hasZone) normalized = '${normalized}Z';
    return DateTime.tryParse(normalized)?.toLocal();
  }
}

class MeshProEntitlements {
  const MeshProEntitlements({
    required this.schemaVersion,
    required this.catalogVersion,
    required this.active,
    required this.features,
    required this.limits,
  });

  const MeshProEntitlements.empty()
    : schemaVersion = 0,
      catalogVersion = '',
      active = false,
      features = const <String, bool>{},
      limits = const <String, int>{};

  factory MeshProEntitlements.fromJson(
    Object? value, {
    bool legacyActive = false,
  }) {
    if (value is! Map) {
      return MeshProEntitlements(
        schemaVersion: 0,
        catalogVersion: '',
        active: legacyActive,
        features: <String, bool>{'meshprivacy_vpn': legacyActive},
        limits: const <String, int>{},
      );
    }
    final json = Map<String, dynamic>.from(value);
    final rawFeatures = json['features'];
    final rawLimits = json['limits'];
    return MeshProEntitlements(
      schemaVersion:
          int.tryParse(json['schema_version']?.toString() ?? '') ?? 0,
      catalogVersion: json['catalog_version']?.toString() ?? '',
      active: json['active'] == true,
      features: rawFeatures is Map
          ? rawFeatures.map(
              (key, item) => MapEntry(key.toString(), item == true),
            )
          : const <String, bool>{},
      limits: rawLimits is Map
          ? rawLimits.map(
              (key, item) =>
                  MapEntry(key.toString(), int.tryParse(item.toString()) ?? 0),
            )
          : const <String, int>{},
    );
  }

  final int schemaVersion;
  final String catalogVersion;
  final bool active;
  final Map<String, bool> features;
  final Map<String, int> limits;

  bool hasFeature(String featureId) => features[featureId] == true;

  int? limitFor(String limitId) => limits[limitId];
}
