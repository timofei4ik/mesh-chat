typedef MeshStudioPreset = ({
  String id,
  String label,
  String background,
  String effect,
  String blink,
  String decoration,
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
  ('mesh', 'Mesh'),
  ('aurora', 'Aurora'),
  ('starlight', 'Starlight'),
  ('stardust', 'Stardust'),
  ('ember', 'Ember'),
  ('sunset', 'Sunset'),
  ('frost', 'Frost'),
  ('orbit', 'Orbit'),
];

const meshStudioPresets = <MeshStudioPreset>[
  (
    id: 'stardust',
    label: 'Stardust',
    background: 'stardust',
    effect: 'stars',
    blink: 'star',
    decoration: 'stardust',
    accent: 0xFF75DFFF,
  ),
  (
    id: 'ember',
    label: 'Ember',
    background: 'ember',
    effect: 'nodes',
    blink: 'dot',
    decoration: 'ember',
    accent: 0xFFFF7A55,
  ),
  (
    id: 'sunset',
    label: 'Sunset',
    background: 'sunset',
    effect: 'orbit',
    blink: 'dot',
    decoration: 'sunset_clouds',
    accent: 0xFFFF79B0,
  ),
  (
    id: 'frost',
    label: 'Frost',
    background: 'frost',
    effect: 'stars',
    blink: 'star',
    decoration: 'frost_bloom',
    accent: 0xFFB9F3FF,
  ),
  (
    id: 'orbit',
    label: 'Orbit',
    background: 'orbit',
    effect: 'orbit',
    blink: 'dot',
    decoration: 'neon_orbit',
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
