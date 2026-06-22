/// A Discord activity (Rich Presence). [type]: 0 Playing · 2 Listening ·
/// 3 Watching. For Watching, [name] is what renders after "Watching ".
class DiscordActivity {
  const DiscordActivity({
    required this.name,
    this.type = 0,
    this.details,
    this.state,
    this.largeImage,
    this.largeText,
    this.smallImage,
    this.smallText,
    this.startMs,
    this.endMs,
    this.buttons = const [],
  });

  final String name;
  final int type;
  final String? details;
  final String? state;

  /// Asset key uploaded to the app, OR an `mp:external/...` key from the
  /// external-assets API (real poster URL).
  final String? largeImage;
  final String? largeText;
  final String? smallImage;
  final String? smallText;
  final int? startMs;
  final int? endMs;
  final List<({String label, String url})> buttons;

  Map<String, dynamic> toJson(String appId) {
    final assets = <String, dynamic>{
      if (largeImage != null) 'large_image': largeImage,
      if (largeText != null) 'large_text': largeText,
      if (smallImage != null) 'small_image': smallImage,
      if (smallText != null) 'small_text': smallText,
    };
    final ts = <String, dynamic>{
      if (startMs != null) 'start': startMs,
      if (endMs != null) 'end': endMs,
    };
    return {
      'name': name,
      'type': type,
      'application_id': appId,
      if (details != null) 'details': details,
      if (state != null) 'state': state,
      if (assets.isNotEmpty) 'assets': assets,
      if (ts.isNotEmpty) 'timestamps': ts,
      if (buttons.isNotEmpty) ...{
        'buttons': [for (final b in buttons) b.label],
        'metadata': {
          'button_urls': [for (final b in buttons) b.url],
        },
      },
    };
  }
}
