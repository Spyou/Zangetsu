import 'download_prefs.dart';

/// Where a finished VIDEO download should end up.
enum VideoDestination {
  /// Leave it in app-private storage. Invisible to every file manager, and
  /// deleted when the app is uninstalled.
  privateStorage,

  /// A detected drive (USB / SSD / SD card) — a plain volume path.
  detectedVolume,

  /// A folder the user picked with the system picker (a `content://` tree).
  safTree,

  /// The public Downloads/Zangetsu folder.
  publicDownloads,
}

/// The one place that decides where a finished video download goes.
///
/// The MP4 and HLS paths each used to branch on the location separately, and
/// they disagreed: the HLS side had an explicit SAF branch, while the MP4 side
/// only ever avoided publishing a picked `content://` folder because the
/// *enqueue* step had already chosen a different task class for it. That
/// coupling is invisible and breaks the moment anything forces a plain task.
/// One function means one answer, and it is testable with no plugins.
VideoDestination videoDestination({
  required bool keepPrivate,
  required String? locationUri,
}) {
  // The toggle is the newest and most explicit statement of intent. A folder
  // picked weeks ago must not quietly override "keep my downloads private".
  if (keepPrivate) return VideoDestination.privateStorage;
  final loc = locationUri;
  if (loc != null && loc.isNotEmpty) {
    return isUriPath(loc)
        ? VideoDestination.safTree
        : VideoDestination.detectedVolume;
  }
  return VideoDestination.publicDownloads;
}
