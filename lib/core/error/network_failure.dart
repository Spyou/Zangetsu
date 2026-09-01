import 'dart:io';

import 'package:dio/dio.dart';

/// Whether [error] means "the request never reached anyone" rather than "the
/// other end said no".
///
/// Deliberately inferred from the failure instead of asking the OS whether a
/// network exists: a phone can be on wifi with no route out, on a captive
/// portal, or behind a DNS block, and every one of those reports "connected"
/// while nothing works. A request that could not open a socket is the honest
/// signal, and it costs no dependency.
///
/// Used to tell an offline screen apart from a dead source — the two looked
/// identical before, so a train tunnel and a broken extension both read as
/// "this source returned nothing".
bool isOfflineError(Object? error) {
  if (error is SocketException) return true;
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return true;
      case DioExceptionType.unknown:
        // Dio wraps the real cause here; a socket failure underneath is still
        // a socket failure.
        return error.error is SocketException;
      default:
        return false;
    }
  }
  // Providers wrap their own failures, so fall back to the message. Narrow on
  // purpose — matching loosely would label a source's own error as offline.
  final s = error?.toString() ?? '';
  return s.contains('SocketException') ||
      s.contains('Failed host lookup') ||
      s.contains('Network is unreachable');
}

/// [isOfflineError], confirmed against a host we don't control.
///
/// A dead source domain fails DNS in exactly the same way a dead network
/// does, so the check above alone would tell someone with perfectly good wifi
/// that they are offline whenever an extension's domain goes down, which in
/// this app is a weekly event rather than an edge case. One lookup settles
/// it: if a name that isn't ours still resolves, the connection is fine and
/// the source is the broken part.
///
/// Only ever runs on the error path, so a healthy load never pays for it.
Future<bool> isOfflineErrorConfirmed(Object? error) async {
  if (!isOfflineError(error)) return false;
  return !await hasRouteOut();
}

/// Whether a name we don't control still resolves. Swappable so tests can
/// answer without real DNS.
Future<bool> Function() hasRouteOut = _lookupSucceeds;

Future<bool> _lookupSucceeds() async {
  try {
    final r = await InternetAddress.lookup(
      'one.one.one.one',
    ).timeout(const Duration(seconds: 3));
    return r.isNotEmpty;
  } on Object {
    return false;
  }
}
