enum StoreDistribution { direct, appStore, play }

abstract final class StoreDistributionConfig {
  static const _raw = String.fromEnvironment(
    'MESH_DISTRIBUTION',
    defaultValue: 'direct',
  );

  static StoreDistribution get current => switch (_raw.toLowerCase()) {
    'appstore' || 'app_store' || 'ios' => StoreDistribution.appStore,
    'play' || 'google_play' => StoreDistribution.play,
    _ => StoreDistribution.direct,
  };

  static bool get allowsExternalMeshProPurchase =>
      current == StoreDistribution.direct;

  static bool get allowsActivationCodes => current == StoreDistribution.direct;

  static String get storeName => switch (current) {
    StoreDistribution.appStore => 'App Store',
    StoreDistribution.play => 'Google Play',
    StoreDistribution.direct => 'MeshHub',
  };
}
