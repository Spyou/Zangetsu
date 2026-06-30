import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';

void main() {
  test('AppMode exposes the injected isTv value', () {
    expect(const AppMode(isTv: true).isTv, isTrue);
    expect(const AppMode(isTv: false).isTv, isFalse);
  });
}
