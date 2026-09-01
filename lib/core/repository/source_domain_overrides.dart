import 'package:hive/hive.dart';

import '../hive/safe_box.dart';

/// A user-set base url for one source, overriding whatever the extension
/// itself reports.
///
/// A CloudStream plugin resolves its own domain at runtime and rewrites
/// `MainAPI.mainUrl`, but a plugin that has stopped being updated keeps
/// pointing at a domain that has since died — and nothing app-side can
/// derive the live one from a dead one (the dead host redirects to a
/// verification gate, not to the new site). The app can't fix the plugin's
/// fetching, but it CAN stop sending the user to a dead address for the
/// things it does own: "open in browser" and the Cloudflare solve.
///
/// Deliberately narrow: this does NOT change where the plugin fetches from.
/// Overriding that would mean rewriting a live plugin's state from Dart and
/// hoping its own resolution doesn't overwrite it a moment later.
class SourceDomainOverrides {
  SourceDomainOverrides._(this._box);
  final Box<String> _box;

  static const String boxName = 'source_domain_overrides';

  static Future<SourceDomainOverrides> open() async =>
      SourceDomainOverrides._(await openBoxSafely<String>(boxName));

  /// The override for [sourceId], or null when the user hasn't set one.
  String? get(String sourceId) {
    final v = _box.get(sourceId)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Stores [url] for [sourceId]. A blank url clears the override instead of
  /// storing an empty one, so "clear the field and save" means "use the
  /// source's own domain again" rather than "use nothing".
  Future<void> set(String sourceId, String url) {
    final v = normalize(url);
    return v == null ? _box.delete(sourceId) : _box.put(sourceId, v);
  }

  Future<void> clear(String sourceId) => _box.delete(sourceId);

  /// [raw] as a storable base url, or null when it isn't one. Adds a missing
  /// scheme (users type "netmirror.gg") and drops a trailing slash so the
  /// value concatenates the same way the extension-reported one does.
  static String? normalize(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return null;
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'https://$v';
    }
    final uri = Uri.tryParse(v);
    if (uri == null || uri.host.isEmpty) return null;
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }
}
