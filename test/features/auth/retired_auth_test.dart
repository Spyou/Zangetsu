import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';

class Service extends SupabaseService {
  Service(this.connection);
  final SupabaseClient connection;
  @override
  SupabaseClient get client => connection;
}

class OfflineCubit extends AuthCubit {
  OfflineCubit(super.service);
  @override
  Future<bool> ensureFreshSession() async => false;
  @override
  bool get hasLiveSession => false;
}

void main() {
  test(
    'failed login makes one Supabase request and reports invalid credentials',
    () async {
      final requests = <Uri>[];
      final client = SupabaseClient(
        'https://auth.test',
        'test-only-key',
        httpClient: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            '{"error":"invalid_grant","error_description":"Invalid login credentials"}',
            400,
          );
        }),
      );
      final cubit = AuthCubit(Service(client));
      expect(
        await cubit.login('user@example.com', 'test-only-password'),
        isFalse,
      );
      expect(requests, hasLength(1));
      expect(requests.single.host, 'auth.test');
      expect(cubit.state.busy, isFalse);
      expect(cubit.state.error, 'Invalid email or password');
      await cubit.close();
      await client.dispose();
    },
  );
  test(
    'offline restore preserves the cached user and asks for reconnection',
    () async {
      final directory = await Directory.systemTemp.createTemp('retired_auth');
      Hive.init(directory.path);
      final cache = await Hive.openBox(AuthCubit.cacheBoxName);
      await cache.put(
        'user',
        jsonEncode({
          'id': 'cached-user',
          'name': 'User',
          'email': 'user@example.com',
        }),
      );
      final client = SupabaseClient('https://auth.test', 'test-only-key');
      final cubit = OfflineCubit(Service(client));
      await cubit.restore();
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.isLoggedIn, isTrue);
      expect(cubit.state.needsReconnect, isTrue);
      expect(cache.containsKey('user'), isTrue);
      await cubit.close();
      await client.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    },
  );
}
