import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_viewport.dart';

void main() {
  testWidgets(
    'normalizes a 1920x1080 TV to 960x540 and preserves output resolution',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      MediaQueryData? normalized;
      var taps = 0;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(1920, 1080),
            devicePixelRatio: 1,
            padding: EdgeInsets.fromLTRB(60, 40, 20, 10),
            viewPadding: EdgeInsets.fromLTRB(60, 40, 20, 10),
            viewInsets: EdgeInsets.only(bottom: 80),
            systemGestureInsets: EdgeInsets.only(left: 16),
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: TvViewport(
              child: Builder(
                builder: (context) {
                  normalized = MediaQuery.of(context);
                  return Align(
                    alignment: Alignment.topLeft,
                    child: GestureDetector(
                      key: const ValueKey('target'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => taps++,
                      child: const SizedBox(width: 74, height: 50),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(normalized?.size, const Size(960, 540));
      expect(normalized?.devicePixelRatio, 2);
      expect(normalized?.padding, const EdgeInsets.fromLTRB(30, 20, 10, 5));
      expect(normalized?.viewInsets, const EdgeInsets.only(bottom: 40));
      expect(normalized?.systemGestureInsets, const EdgeInsets.only(left: 8));

      final box = tester.renderObject<RenderBox>(
        find.byKey(const ValueKey('target')),
      );
      final topLeft = box.localToGlobal(Offset.zero);
      final bottomRight = box.localToGlobal(
        Offset(box.size.width, box.size.height),
      );
      expect(bottomRight - topLeft, const Offset(148, 100));

      await tester.tapAt(const Offset(74, 50));
      expect(taps, 1);
    },
  );

  testWidgets('leaves a 960x540 TV at its native logical scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    MediaQueryData? normalized;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(960, 540), devicePixelRatio: 2),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: TvViewport(
            child: Builder(
              builder: (context) {
                normalized = MediaQuery.of(context);
                return const Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    key: ValueKey('target'),
                    width: 74,
                    height: 50,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(normalized?.size, const Size(960, 540));
    expect(normalized?.devicePixelRatio, 2);

    final box = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('target')),
    );
    final topLeft = box.localToGlobal(Offset.zero);
    final bottomRight = box.localToGlobal(
      Offset(box.size.width, box.size.height),
    );
    expect(bottomRight - topLeft, const Offset(74, 50));
  });
}
