import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/environment.dart';

void main() {
  test('cloud sync defaults to the production VPS', () {
    expect(Environment.vpsSyncUrl, 'https://sync.AniAura.online');
  });
}
