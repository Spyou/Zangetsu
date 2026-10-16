import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// Creates a 256-bit random pairing credential encoded as hexadecimal.
String companionSecret() => List.generate(
  32,
  (_) => Random.secure().nextInt(256),
).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Computes the protocol HMAC proof over the receiver nonce using the shared credential.
String companionProof(String secret, String nonce) =>
    Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(nonce)).toString();

/// Compares complete proofs without returning early on a differing character.
bool companionProofMatches(String a, String b) {
  var difference = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ (i < b.length ? b.codeUnitAt(i) : 0);
  }
  return difference == 0;
}

/// The same bounded, ordered JSON-line protocol used by the Android receiver.
/// Closing a failed exchange is intentional: uncertain commands are not replayed.
class CompanionWire {
  /// Frames UTF-8 JSON by newline, caps frame size, and propagates stream backpressure.
  CompanionWire(this.socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final subscription = socket.listen(
      (bytes) {
        if (!alive) return;
        for (final byte in bytes) {
          if (byte == 10) {
            try {
              _frames.add(
                Map<String, dynamic>.from(
                  jsonDecode(utf8.decode(_buffer)) as Map,
                ),
              );
            } catch (e, stack) {
              _frames.addError(e, stack);
              close();
              return;
            }
            _buffer.clear();
          } else {
            _buffer.add(byte);
            if (_buffer.length > 262144) {
              _frames.addError(
                const FormatException('TV response is too large'),
              );
              close();
              return;
            }
          }
        }
      },
      onError: (Object e, StackTrace stack) {
        if (!alive) return;
        _frames.addError(e, stack);
        close();
      },
      onDone: close,
    );
    _frames.onPause = subscription.pause;
    _frames.onResume = subscription.resume;
    _reader = StreamIterator(_frames.stream);
  }
  final Socket socket;
  final _frames = StreamController<Map<String, dynamic>>();
  final _buffer = <int>[];
  late final StreamIterator<Map<String, dynamic>> _reader;
  bool alive = true;
  int _sequence = 0;
  Future<void> _tail = Future.value();

  /// Reads one frame within the deadline; a timeout closes the uncertain connection.
  Future<Map<String, dynamic>> read({
    Duration timeout = const Duration(seconds: 95),
  }) async {
    try {
      if (!await _reader.moveNext().timeout(timeout))
        throw StateError('TV disconnected');
      return _reader.current;
    } catch (_) {
      close();
      rethrow;
    }
  }

  /// Writes one bounded frame; callers must authenticate before sending commands.
  void send(Map<String, dynamic> frame) {
    if (!alive) throw StateError('TV disconnected');
    final data = utf8.encode(jsonEncode(frame));
    if (data.length > 262144) throw StateError('Command is too large');
    socket.add([...data, 10]);
  }

  /// Queues a command with a monotonic ID; mismatched replies terminate this transport.
  Future<Map<String, dynamic>> exchange(Map<String, dynamic> command) {
    final result = Completer<Map<String, dynamic>>();
    _tail = _tail.then((_) async {
      try {
        final id = ++_sequence;
        send({...command, 'id': id});
        final response = await read(
          timeout: Duration(seconds: command['action'] == 'state' ? 4 : 90),
        );
        if (response['id'] != id) throw StateError('Unexpected TV response');
        result.complete(response);
      } catch (e, stack) {
        close();
        result.completeError(e, stack);
      }
    });
    return result.future;
  }

  /// Idempotently closes the socket and stops delivering frames.
  void close() {
    if (!alive) return;
    alive = false;
    socket.destroy();
    unawaited(_frames.close());
  }
}
