import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/disintegrating_poster.dart';

/// 12×12 opaque red snapshot — exercises the real field builder and painter
/// without touching the engine.
AshField _redField() {
  const w = 12, h = 12;
  final rgba = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    rgba[i * 4] = 200;
    rgba[i * 4 + 3] = 255;
  }
  return AshField.build(rgba, w, h, 0.5)!;
}

void main() {
  test('ashFront dissolves bottom-right first, top-left last', () {
    const phase = 0.0;
    expect(ashFront(1, 1, phase), greaterThan(ashFront(0, 0, phase)));
    for (var i = 0; i <= 10; i++) {
      for (var j = 0; j <= 10; j++) {
        final v = ashFront(i / 10, j / 10, phase);
        expect(v, greaterThanOrEqualTo(-0.2));
        expect(v, lessThanOrEqualTo(1.2));
      }
    }
  });

  test('AshField.build rejects garbage, tiles real pixels', () {
    expect(AshField.build(Uint8List(0), 0, 0, 0), isNull);
    final field = _redField();
    expect(field.tiles, isNotEmpty);
    expect(field.tiles.length, field.cols * field.rows);
    // Stagger is real: not every tile starts at once.
    final delays = field.tiles.map((t) => t.startDelay).toSet();
    expect(delays.length, greaterThan(1));
  });

  testWidgets('renders child untouched when not disintegrating', (t) async {
    var fired = false;
    await t.pumpWidget(
      MaterialApp(
        home: DisintegratingPoster(
          disintegrating: false,
          onDisintegrated: () => fired = true,
          child: const Text('poster'),
        ),
      ),
    );
    expect(find.text('poster'), findsOneWidget);
    expect(fired, isFalse);
  });

  testWidgets('full animation commits the delete on completion', (t) async {
    var fired = false;
    var gone = false;
    var disintegrating = false;
    await t.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => gone
              ? const Text('removed')
              : Column(
                  children: [
                    DisintegratingPoster(
                      disintegrating: disintegrating,
                      onDisintegrated: () {
                        fired = true;
                        setState(() => gone = true);
                      },
                      debugCapture: () async => _redField(),
                      child: const Text('poster'),
                    ),
                    TextButton(
                      onPressed: () => setState(() => disintegrating = true),
                      child: const Text('delete'),
                    ),
                  ],
                ),
        ),
      ),
    );
    await t.tap(find.text('delete'));
    await t.pump();
    await t.pump();
    // Ash is on screen, slot still held ...
    expect(find.text('poster'), findsNothing);
    await t.pump(const Duration(milliseconds: 900));
    await t.pump(const Duration(milliseconds: 700));
    expect(fired, isTrue);
    expect(find.text('removed'), findsOneWidget);
  });

  testWidgets('no-capture fallback still commits the delete', (t) async {
    var fired = false;
    await t.pumpWidget(
      MaterialApp(
        home: DisintegratingPoster(
          disintegrating: true,
          onDisintegrated: () => fired = true,
          debugCapture: () async => null,
          child: const Text('poster'),
        ),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(fired, isTrue);
  });

  testWidgets('slow list keeps the poster, never an empty slot', (t) async {
    // A remote-backed list (tracker refresh) can lag seconds behind the
    // commit. The widget must fall back to the plain poster — not a hole —
    // until the parent drops the entry.
    var fired = false;
    var disintegrating = false;
    await t.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              DisintegratingPoster(
                disintegrating: disintegrating,
                onDisintegrated: () => fired = true,
                debugCapture: () async => _redField(),
                child: const Text('poster'),
              ),
              TextButton(
                onPressed: () => setState(() => disintegrating = true),
                child: const Text('delete'),
              ),
            ],
          ),
        ),
      ),
    );
    await t.tap(find.text('delete'));
    await t.pump();
    await t.pump();
    await t.pump(const Duration(seconds: 2));
    expect(fired, isTrue);
    // Parent hasn't dropped the entry (slow refresh): poster back, no hole.
    expect(find.text('poster'), findsOneWidget);
  });
}
