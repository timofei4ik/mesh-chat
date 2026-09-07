const messageBubbleStyles = <String, String>{
  'auto': 'Profile collection',
  'none': 'No artwork',
  'nebula': 'Nebula',
  'ocean': 'Ocean',
  'sakura': 'Sakura',
  'solar': 'Solar',
  'stardust': 'Stardust',
  'ember': 'Ember',
  'sunset': 'Sunset',
  'frost': 'Frost',
  'orbit': 'Orbit',
  'camp_clouds': 'Spirit Garden',
  'camp_moon': 'Tidal Shrine',
  'camp_ember': 'Moonflower Courtyard',
  'camp_stories': 'Sunken Lotus Garden',
  'camp_rainlight': 'Rainlight Conservatory',
  'remote_skybound_camp': 'Skybound Camp',
  'remote_moonlit_path': 'Moonlit Path',
  'remote_ember_vale': 'Ember Vale',
  'remote_lantern_stories': 'Lantern Stories',
};

String normalizeMessageBubbleStyle(String? value) =>
    messageBubbleStyles.containsKey(value) ? value! : 'auto';
