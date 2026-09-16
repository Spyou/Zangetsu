// The native tile decoder does not exist on the machine `flutter test` runs
// on — this is a Dart VM host process, not an Android device carrying
// libtile_decoder.so. That makes it a free, no-device stand-in for the exact
// failure Task 1 warned about: on API 24-29 the .so is present but its
// AImageDecoder_* symbols are not, so the library load (or symbol lookup)
// fails outright. tileDecodingAvailable() must swallow that and report
// unavailable rather than let it throw into the reader.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/tiles/tile_decoder_ffi.dart';

void main() {
  test(
    'tileDecodingAvailable reports false, not an exception, when the '
    'native library cannot be used',
    () {
      expect(() => tileDecodingAvailable(), returnsNormally);
      expect(tileDecodingAvailable(), isFalse);
    },
  );
}
