import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/error/network_failure.dart';

void main() {
  final req = RequestOptions(path: '/x');

  tearDown(() => hasRouteOut = _realRouteOut);

  group('isOfflineError', () {
    test('socket failures count as offline', () {
      expect(isOfflineError(const SocketException('no route')), isTrue);
      expect(
        isOfflineError(
          DioException(requestOptions: req, type: DioExceptionType.connectionError),
        ),
        isTrue,
      );
    });

    test('a source saying no is not offline', () {
      // The whole point of the split: a 403 or a bad response is the source
      // failing, and telling someone to check their wifi over it is wrong.
      expect(
        isOfflineError(
          DioException(requestOptions: req, type: DioExceptionType.badResponse),
        ),
        isFalse,
      );
      expect(isOfflineError(Exception('no episodes found')), isFalse);
    });
  });

  group('isOfflineErrorConfirmed', () {
    test('a dead source domain is not reported as offline', () async {
      // DNS failing for one host while the rest of the internet resolves means
      // the extension died, not the connection. This is the case that used to
      // tell someone on good wifi that they were offline.
      hasRouteOut = () async => true;
      expect(
        await isOfflineErrorConfirmed(
          const SocketException('Failed host lookup: dead-source.example'),
        ),
        isFalse,
      );
    });

    test('a real outage still reports offline', () async {
      hasRouteOut = () async => false;
      expect(
        await isOfflineErrorConfirmed(const SocketException('no route')),
        isTrue,
      );
    });

    test('non-network errors never trigger a lookup', () async {
      hasRouteOut = () async => fail('should not probe for a source error');
      expect(await isOfflineErrorConfirmed(Exception('parse failed')), isFalse);
    });
  });
}

final _realRouteOut = hasRouteOut;
