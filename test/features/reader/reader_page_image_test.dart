import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/reader_page_image.dart';

class _PendingImage extends ImageProvider<_PendingImage> {
  final frame = Completer<ImageInfo>();

  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _PendingImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(frame.future);
}

void main() {
  testWidgets('zoom keeps a frame, a new page hides it, and errors end loading', (
    tester,
  ) async {
    final image = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAIAAABACAIAAAC/RDEUAAAAGUlEQVR4nGP8//8/AwMDEwMYMI1STEMrCACm0QN9cILuRwAAAABJRU5ErkJggg==',
        ),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    });
    final loaded = _PendingImage();
    final pending = _PendingImage();
    Widget page(String url, ImageProvider provider) => MaterialApp(
      home: ReaderPageImage(
        pageUrl: url,
        image: provider,
        fit: BoxFit.contain,
        placeholderBuilder: (_, _) => const Text('Loading'),
        errorBuilder: (_, _, _) => const Text('Failed'),
        onLoaded: () {},
      ),
    );
    try {
      await tester.pumpWidget(page('first', loaded));
      loaded.frame.complete(ImageInfo(image: image!.clone()));
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);

      await tester.pumpWidget(page('first', pending));
      expect(find.text('Loading'), findsNothing);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);

      await tester.pumpWidget(page('second', pending));
      expect(find.text('Loading'), findsOneWidget);
      pending.frame.completeError(StateError('Invalid image bytes'));
      await tester.pumpAndSettle();
      expect(find.text('Loading'), findsNothing);
      expect(find.text('Failed'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      image?.dispose();
    }
  });
}
