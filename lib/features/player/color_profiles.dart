/// Named colour/visual profiles applied through mpv's video-equalizer
/// properties (brightness / contrast / saturation / gamma / hue, each -100..100,
/// 0 = neutral). "Natural" is all zeros = mpv's default = no change, so it's
/// byte-identical to stock playback. Runtime-settable; works on the gpu / gpu-
/// next renderer without a re-init.
class ColorProfile {
  final String id;
  final String label;
  final int brightness;
  final int contrast;
  final int saturation;
  final int gamma;
  final int hue;
  const ColorProfile(
    this.id,
    this.label, {
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.gamma = 0,
    this.hue = 0,
  });
}

class ColorProfiles {
  ColorProfiles._();

  static const List<ColorProfile> all = [
    ColorProfile('natural', 'Natural'), // default — no adjustment
    ColorProfile('cinema', 'Cinema',
        brightness: 2, contrast: 12, saturation: 8, gamma: 5),
    ColorProfile('cinema_dark', 'Cinema Dark',
        brightness: -12, contrast: 18, saturation: 6, gamma: 12, hue: -1),
    ColorProfile('anime', 'Anime',
        brightness: 10, contrast: 22, saturation: 30, gamma: -3, hue: 3),
    ColorProfile('anime_vibrant', 'Anime Vibrant',
        brightness: 14, contrast: 28, saturation: 42, gamma: -6, hue: 4),
    ColorProfile('anime_soft', 'Anime Soft',
        brightness: 8, contrast: 16, saturation: 25, gamma: -1, hue: 2),
    ColorProfile('vivid', 'Vivid',
        brightness: 8, contrast: 25, saturation: 35, gamma: 2, hue: 1),
    ColorProfile('warm', 'Warm',
        brightness: 3, contrast: 10, saturation: 15, gamma: 2, hue: 6),
    ColorProfile('cool', 'Cool',
        brightness: 1, contrast: 8, saturation: 12, gamma: 1, hue: -6),
    ColorProfile('grayscale', 'Grayscale',
        brightness: 2, contrast: 20, saturation: -100, gamma: 8),
  ];

  static ColorProfile byId(String id) =>
      all.firstWhere((p) => p.id == id, orElse: () => all.first);
}
