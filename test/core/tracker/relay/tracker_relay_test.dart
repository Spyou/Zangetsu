import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tracker/relay/tracker_blob.dart';
import 'package:watch_app/core/tracker/relay/tracker_relay.dart';
import 'package:watch_app/core/tracker/tracker.dart';

class _FakeTracker extends ChangeNotifier implements Tracker {
  @override
  bool get supportsReading => true;

  _FakeTracker(this._session);
  Map<String, dynamic>? _session;
  Map<String, dynamic>? get written => _written;
  Map<String, dynamic>? _written;

  @override
  Map<String, dynamic>? exportSession() => _session;
  @override
  Future<void> importSession(Map<String, dynamic> s) async {
    _written = s;
    _session = s;
    notifyListeners();
  }
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('pack includes only connected trackers', () {
    final relay = TrackerRelay({
      'anilist': _FakeTracker({'accessToken': 'a'}),
      'mal': _FakeTracker(null), // not connected
      'simkl': _FakeTracker({'accessToken': 's'}),
    });
    final blob = relay.pack();
    expect(blob.trackers.keys.toSet(), {'anilist', 'simkl'});
    expect(blob.version, TrackerBlob.currentVersion);
  });

  test('pack(only:) restricts to the requested ids', () {
    final relay = TrackerRelay({
      'anilist': _FakeTracker({'accessToken': 'a'}),
      'simkl': _FakeTracker({'accessToken': 's'}),
    });
    expect(relay.pack(only: {'simkl'}).trackers.keys.toSet(), {'simkl'});
  });

  test('unpack writes each present tracker and reports applied ids', () async {
    final mal = _FakeTracker(null);
    final relay = TrackerRelay({'mal': mal, 'simkl': _FakeTracker(null)});
    const blob = TrackerBlob(version: 1, trackers: {
      'mal': {'accessToken': 'x'},
      'unknown': {'accessToken': 'y'}, // ignored
    });
    final applied = await relay.unpack(blob);
    expect(applied, ['mal']);
    expect(mal.written, {'accessToken': 'x'});
  });
}
