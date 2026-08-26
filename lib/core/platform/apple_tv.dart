import 'dart:io' show Platform;

/// Whether this isolate is running on Apple TV (tvOS).
///
/// Dart reports tvOS as [Platform.isIOS]; the OS version string is what
/// distinguishes it (contains `TVOS` / `tvOS`). False on iPhone/iPad and
/// every non-Apple platform.
bool get isAppleTv {
  if (!Platform.isIOS) return false;
  final v = Platform.operatingSystemVersion.toLowerCase();
  return v.contains('tvos') || v.contains('apple tv');
}
