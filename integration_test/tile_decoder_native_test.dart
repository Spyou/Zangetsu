import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:watch_app/core/reading/tiles/tile_decoder_ffi.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String path;

  setUpAll(() async {
    // The decoders need a real file descriptor, so the fixture is copied out
    // of the asset bundle and onto disk first.
    final bytes = await rootBundle.load(
      'test/fixtures/tile_fixture_640x480.png',
    );
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/tile_fixture.png');
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    path = file.path;
  });

  test('reports the image size without decoding it', () {
    if (!tileDecodingAvailable()) return; // below API 30
    final handle = tileOpen(path);
    expect(handle, isNotNull);
    expect(handle!.width, 640);
    expect(handle.height, 480);
    tileClose(handle);
  });

  test('decodes the top-left quadrant and it is red', () {
    if (!tileDecodingAvailable()) return;
    final handle = tileOpen(path)!;
    final tile = tileDecode(handle, 0, 0, 320, 240, 1);
    expect(tile, isNotNull);
    expect(tile!.width, 320);
    expect(tile.height, 240);
    // Centre of the tile, read through the reported stride — NOT width * 4.
    final i = (120 * tile.stride) + (160 * 4);
    expect(tile.rgba[i], 255, reason: 'red');
    expect(tile.rgba[i + 1], 0, reason: 'green');
    expect(tile.rgba[i + 2], 0, reason: 'blue');
    tileClose(handle);
  });

  test('decodes the bottom-right quadrant and it is white', () {
    if (!tileDecodingAvailable()) return;
    final handle = tileOpen(path)!;
    final tile = tileDecode(handle, 320, 240, 320, 240, 1)!;
    final i = (120 * tile.stride) + (160 * 4);
    expect(tile.rgba[i], 255);
    expect(tile.rgba[i + 1], 255);
    expect(tile.rgba[i + 2], 255);
    tileClose(handle);
  });

  test('a sample size of 2 halves the output', () {
    if (!tileDecodingAvailable()) return;
    final handle = tileOpen(path)!;
    // At sample 2 the image is 320x240, so the whole image is that rect.
    final tile = tileDecode(handle, 0, 0, 320, 240, 2)!;
    expect(tile.width, 320);
    expect(tile.height, 240);
    tileClose(handle);
  });

  test('a rect outside the image is refused, not clamped', () {
    if (!tileDecodingAvailable()) return;
    final handle = tileOpen(path)!;
    expect(tileDecode(handle, 600, 400, 200, 200, 1), isNull);
    tileClose(handle);
  });

  test('a file that is not an image returns null rather than crashing', () async {
    final dir = await getTemporaryDirectory();
    final junk = File('${dir.path}/not_an_image.png');
    await junk.writeAsString('this is not a png');
    expect(tileOpen(junk.path), isNull);
  });
}
