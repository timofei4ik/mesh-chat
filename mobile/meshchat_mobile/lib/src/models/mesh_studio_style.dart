typedef MeshStudioPreset = ({
  String id,
  String label,
  String background,
  String effect,
  String blink,
  String decoration,
  String messageEffect,
  int accent,
});

const meshStudioProfileAccents = <int>[
  0xFF42A5F5,
  0xFF3BD6FF,
  0xFFA56BFF,
  0xFF67F3C4,
  0xFFFF6B9C,
  0xFFFFB65C,
];

const meshStudioAvatarDecorations = <(String, String)>[
  ('none', 'None'),
  ('stardust', 'Stardust'),
  ('ember', 'Ember'),
  ('sunset_clouds', 'Sunset'),
  ('neon_orbit', 'Orbit'),
  ('frost_bloom', 'Frost'),
];

const meshStudioBackgrounds = <(String, String)>[
  ('nebula', 'Nebula'),
  ('ocean', 'Neon Tide'),
  ('sakura', 'Sakura'),
  ('solar', 'Solar'),
  ('ember', 'Ember'),
  ('sunset', 'Sunset'),
  ('frost', 'Frost'),
  ('orbit', 'Orbit'),
];

const meshStudioPresets = <MeshStudioPreset>[
  (
    id: 'nebula',
    label: 'Nebula',
    background: 'nebula',
    effect: 'stars',
    blink: 'star',
    decoration: 'neon_orbit',
    messageEffect: 'orbit',
    accent: 0xFFC46BFF,
  ),
  (
    id: 'tide',
    label: 'Neon Tide',
    background: 'ocean',
    effect: 'nodes',
    blink: 'dot',
    decoration: 'frost_bloom',
    messageEffect: 'frost',
    accent: 0xFF42E8D1,
  ),
  (
    id: 'sakura',
    label: 'Sakura',
    background: 'sakura',
    effect: 'stars',
    blink: 'star',
    decoration: 'sunset_clouds',
    messageEffect: 'sunset',
    accent: 0xFFFF79B8,
  ),
  (
    id: 'solar',
    label: 'Solar',
    background: 'solar',
    effect: 'orbit',
    blink: 'dot',
    decoration: 'ember',
    messageEffect: 'ember',
    accent: 0xFFFFB34D,
  ),
  (
    id: 'stardust',
    label: 'Stardust',
    background: 'stardust',
    effect: 'stars',
    blink: 'star',
    decoration: 'stardust',
    messageEffect: 'stardust',
    accent: 0xFF75DFFF,
  ),
  (
    id: 'ember',
    label: 'Ember',
    background: 'ember',
    effect: 'nodes',
    blink: 'dot',
    decoration: 'ember',
    messageEffect: 'ember',
    accent: 0xFFFF7A55,
  ),
  (
    id: 'sunset',
    label: 'Sunset',
    background: 'sunset',
    effect: 'orbit',
    blink: 'dot',
    decoration: 'sunset_clouds',
    messageEffect: 'sunset',
    accent: 0xFFFF79B0,
  ),
  (
    id: 'frost',
    label: 'Frost',
    background: 'frost',
    effect: 'stars',
    blink: 'star',
    decoration: 'frost_bloom',
    messageEffect: 'frost',
    accent: 0xFFB9F3FF,
  ),
  (
    id: 'orbit',
    label: 'Orbit',
    background: 'orbit',
    effect: 'orbit',
    blink: 'dot',
    decoration: 'neon_orbit',
    messageEffect: 'orbit',
    accent: 0xFFA56BFF,
  ),
];

String matchingMeshStudioPreset({
  required String background,
  required String effect,
  required String blink,
  required String decoration,
  required int accent,
}) {
  for (final preset in meshStudioPresets) {
    if (background == preset.background &&
        effect == preset.effect &&
        blink == preset.blink &&
        decoration == preset.decoration &&
        accent == preset.accent) {
      return preset.id;
    }
  }
  return 'custom';
}
