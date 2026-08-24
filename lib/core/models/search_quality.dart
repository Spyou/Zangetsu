/// Poster badge text for a CloudStream `SearchQuality`.
///
/// The bridge sends the raw enum name; these are the sixteen values the
/// CloudStream library defines. Anything unrecognised (a newer value, a
/// provider writing its own string) is passed through uppercased rather than
/// dropped — an unknown label still tells the viewer more than no label.
///
/// Null in, null out: most providers never set a quality, so no badge is the
/// normal case rather than a failure.
String? qualityBadgeLabel(String? raw) {
  final v = raw?.trim();
  if (v == null || v.isEmpty) return null;
  return switch (v) {
    'Cam' => 'CAM',
    'CamRip' => 'CAM',
    'HdCam' => 'HD CAM',
    'Telesync' => 'TS',
    'WorkPrint' => 'WP',
    'Telecine' => 'TC',
    'HQ' => 'HQ',
    'HD' => 'HD',
    'HDR' => 'HDR',
    'BlueRay' => 'BLURAY',
    'DVD' => 'DVD',
    'SD' => 'SD',
    'FourK' => '4K',
    'UHD' => '4K',
    'SDR' => 'SDR',
    'WebRip' => 'WEB',
    _ => v.toUpperCase(),
  };
}

/// Poster badge text for a CloudStream anime listing's `DubStatus` set.
///
/// "Subbed"/"Dubbed" in, "SUB"/"DUB"/"SUB DUB" out. `None` is CloudStream's
/// "not applicable" member rather than a real state, so it is ignored — a set
/// containing only None means the source told us nothing and gets no badge.
String? dubBadgeLabel(List<String>? raw) {
  if (raw == null || raw.isEmpty) return null;
  final sub = raw.contains('Subbed');
  final dub = raw.contains('Dubbed');
  if (sub && dub) return 'SUB DUB';
  if (dub) return 'DUB';
  if (sub) return 'SUB';
  return null;
}
