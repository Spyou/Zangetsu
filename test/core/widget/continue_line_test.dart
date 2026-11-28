import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/widget/continue_widget_service.dart';

void main() {
  test('shows episode and minutes left', () {
    expect(
      continueLine(
        number: 12,
        duration: const Duration(minutes: 24),
        position: const Duration(minutes: 15),
      ),
      'Episode 12 · 9 min left',
    );
  });

  test('keeps a fractional episode number', () {
    expect(
      continueLine(
        number: 12.5,
        duration: const Duration(minutes: 24),
        position: const Duration(minutes: 23, seconds: 30),
      ),
      'Episode 12.5 · under a minute left',
    );
  });

  test('no duration or number falls back gracefully', () {
    expect(
      continueLine(number: 3, duration: Duration.zero, position: Duration.zero),
      'Episode 3',
    );
    expect(
      continueLine(duration: Duration.zero, position: Duration.zero),
      'Episode',
    );
  });
}
