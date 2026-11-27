/// Zone key the playback resolver sets (true) while it asks a source the viewer
/// picked by hand. The CloudStream provider reads it to know it may keep waiting
/// on a slow link hunt (some sources need ~30s) instead of reporting "no links"
/// after the short native wait. Everything else keeps the quick behaviour.
final Object patientLinksKey = Object();
