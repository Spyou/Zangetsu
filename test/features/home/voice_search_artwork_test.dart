import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/home/voice_search_artwork.dart';

void main() {
  test('chooses a supported GIF and never repeats the last one', () {
    final picker = VoiceSearchArtwork(random: Random(7));
    String? previous;
    for (var i = 0; i < 30; i++) {
      final chosen = picker.next();
      expect(VoiceSearchArtwork.urls, contains(chosen));
      expect(chosen, isNot(previous));
      previous = chosen;
    }
  });

  test('either character can be selected first', () {
    final firstChoices = {
      for (var seed = 0; seed < 20; seed++)
        VoiceSearchArtwork(random: Random(seed)).next(),
    };
    expect(firstChoices, containsAll(VoiceSearchArtwork.urls));
  });
}
