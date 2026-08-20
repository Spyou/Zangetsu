import '../models/episode.dart';
import '../models/episode_title.dart';

/// Presence "details" line: episode number plus a real title when we have one.
/// Discord caps [details] at 128 characters.
String? discordEpisodeLabel(Episode ep, {int? fallbackNumber}) {
  final out = episodePresenceDetails(ep, fallbackNumber: fallbackNumber);
  if (out == null) return null;
  if (out.length <= 128) return out;
  return '${out.substring(0, 127)}…';
}

/// Unix-ms timestamps Discord uses to draw a Rich Presence progress bar.
///
/// Both [startMs] and [endMs] must be set for a bar; start-only is elapsed
/// time; omitting both (paused / unknown) shows no timer so the bar cannot
/// keep marching on wall-clock time after a pause.
({int? startMs, int? endMs}) discordPlaybackTimestamps({
  required Duration position,
  required Duration duration,
  required bool playing,
  DateTime? now,
}) {
  if (!playing) return (startMs: null, endMs: null);
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final posMs = position.inMilliseconds < 0 ? 0 : position.inMilliseconds;
  final startMs = nowMs - posMs;
  if (duration <= Duration.zero) return (startMs: startMs, endMs: null);
  return (startMs: startMs, endMs: startMs + duration.inMilliseconds);
}

/// Gateway `op: 3` presence payload. A null [activity] is an explicit clear
/// (`activities: []`) — dropping the socket without this leaves the last
/// Rich Presence stuck on the profile.
Map<String, dynamic> discordPresenceUpdate(DiscordActivity? activity, String appId) {
  return {
    'since': null,
    'activities': activity == null
        ? <dynamic>[]
        : [activity.toJson(appId)],
    'status': 'online',
    'afk': false,
  };
}

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
