import 'package:AniAura_source_bridge/AniAura_source_bridge.dart';

MangayomiContentType? mangayomiContentTypeOf(String sourceId) {
  final parts = sourceId.split(':');
  if (parts.length != 5 || parts[0] != 'mg' || parts[1].isEmpty) return null;
  final type = int.tryParse(parts[2]);
  final language = int.tryParse(parts[3]);
  final id = int.tryParse(parts[4]);
  if (type == null || type < 0 || type >= MangayomiContentType.values.length) {
    return null;
  }
  if (language == null ||
      language < 0 ||
      language > 1 ||
      id == null ||
      id == 0) {
    return null;
  }
  return MangayomiContentType.values[type];
}
