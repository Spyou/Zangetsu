import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/supabase/auth_user.dart';

void main() {
  test('displayName prefers name, falls back to email', () {
    expect(const AuthUser(id: '1', name: 'Krishna', email: 'k@x.com').displayName, 'Krishna');
    expect(const AuthUser(id: '1', name: '', email: 'k@x.com').displayName, 'k@x.com');
  });
}
