import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/features/player/player_screen.dart';

void main() {
  test('PlayerScreen exposes an optional cubit parameter', () {
    // Compile-time contract: the named parameter must exist and default to
    // null. Adapted from the brief's exact snippet — that one didn't compile
    // (resolveSources' return type is Future<List<VideoSource>>, not
    // Future<List<dynamic>>, and `null as dynamic` isn't a valid constant for
    // the non-nullable `resume` field). A plain ResumeStore() is cheap to
    // build and is never touched since the widget is never pumped.
    final screen = PlayerScreen(
      sourceId: 'test',
      resume: ResumeStore(),
      resolveSources: _noSources,
    );
    expect(screen.cubit, isNull);
  });
}

Future<List<VideoSource>> _noSources(String _) async => const [];
