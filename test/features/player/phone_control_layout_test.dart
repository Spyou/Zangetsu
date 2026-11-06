import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/phone_playback_launch.dart';

void main() {
  Map<String, dynamic> payload() => {
    'sessionId': 7,
    'top': ['info'],
    'left': ['speed', 'enhance', 'colour', 'more'],
    'right': ['episodes', 'rotate', 'fit'],
  };
  test('native saves preserve valid controls for the other engine', () {
    final layout = phoneControlLayoutForSave(
      payload(),
      sessionId: 7,
      playerOpen: true,
    )!;
    expect(layout.left, ['speed', 'enhance', 'colour', 'more']);
    expect(layout.top, ['info']);
  });
  test('stale and closed sessions cannot overwrite saved controls', () {
    expect(
      phoneControlLayoutForSave(payload(), sessionId: 8, playerOpen: true),
      isNull,
    );
    expect(
      phoneControlLayoutForSave(payload(), sessionId: 7, playerOpen: false),
      isNull,
    );
  });
  test('malformed writes do not clear the saved arrangement', () {
    expect(
      phoneControlLayoutForSave(
        payload()..remove('left'),
        sessionId: 7,
        playerOpen: true,
      ),
      isNull,
    );
    expect(
      phoneControlLayoutForSave(
        payload()..['left'] = [1],
        sessionId: 7,
        playerOpen: true,
      ),
      isNull,
    );
  });
  test('duplicates and unknown ids are cleaned and More stays available', () {
    final layout = phoneControlLayoutForSave(
      payload()..['left'] = ['info', 'unknown'],
      sessionId: 7,
      playerOpen: true,
    )!;
    expect(layout.left, ['more']);
    expect(layout.top, ['info']);
  });
}
