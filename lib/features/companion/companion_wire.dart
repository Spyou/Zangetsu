import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/export.dart' as pc;

/// Creates a 256-bit random pairing credential encoded as hexadecimal.
String companionSecret() => List.generate(
  32,
  (_) => Random.secure().nextInt(256),
).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// HMAC-SHA256 of [message] keyed by [secret], as lowercase hex. Pairing
/// proofs must go through [companionPairingProof], never a bare nonce.
String companionProof(String secret, String message) =>
    Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(message)).toString();

/// Pairing protocol version sent in the TV challenge and the phone hello.
/// Version 2 binds both ECDH public keys into the proofs; version 1 proofs
/// covered only the nonce and are refused.
///
/// Security limits of version 2, kept on purpose until a later version:
/// - Only the pairing and the remembered token are protected. Binding both
///   keys stops an active attacker from swapping keys to learn the token, but
///   frames after 'paired' travel unencrypted with no per-message MAC (the
///   command loop only checks that IDs increase). An attacker who sits between
///   phone and TV can relay the handshake unchanged and then inject or alter
///   commands for that session, remembered reconnects included. Fixing this
///   needs a session key from the ECDH secret (and the token for remembered
///   mode) that MACs or AES-GCM-seals every frame.
/// - PIN mode is weak against an active attacker: the phone's proof is keyed
///   by a 6-digit PIN over a transcript the attacker sees, so the PIN falls to
///   about 10^6 offline HMACs before the attacker's single real attempt; the
///   TV's rate limit and single-use PIN do not help. QR pairing (256-bit
///   secret) is the recommended path; only a PAKE (CPace, SPAKE2) would fix PIN.
const companionPairingVersion = 2;

/// Error the TV returns to a phone that still sends a version-1 proof.
const companionOldPhoneError =
    'Update Zangetsu on this phone to pair with the TV.';

/// Error a phone shows when the TV still speaks pairing version 1.
const companionOldTvError =
    'Update Zangetsu on the TV to pair with this phone.';

/// Pairing nonce sent by the TV: 32 random bytes as lowercase hex.
final companionNoncePattern = RegExp(r'^[0-9a-f]{64}$');

/// The exact pairing transcript both sides MAC. Every field is a fixed-
/// alphabet string checked before use (hex keys and nonce, a closed mode set,
/// a [a-zA-Z0-9-] client ID), so '|' cannot appear inside one. The keys are
/// the exact hex strings sent on the wire; [clientKey] is empty for a
/// remembered reconnect, which sends no key. [label] is 'phone' for the
/// phone's proof and 'tv' for the TV's answer, so neither can be replayed as
/// the other. Matches CompanionReceiver.pairingTranscript byte for byte.
String companionTranscript({
  required String label,
  required String mode,
  required String nonce,
  required String tvKey,
  required String clientKey,
  required String clientId,
}) =>
    'zangetsu-pair-v$companionPairingVersion|$label|$mode|$nonce|$tvKey|$clientKey|$clientId';

/// HMAC proof over the pairing transcript with the pairing secret (QR secret,
/// PIN, or remembered token). Matches CompanionReceiver.pairingProof.
String companionPairingProof(
  String secret, {
  required String label,
  required String mode,
  required String nonce,
  required String tvKey,
  required String clientKey,
  required String clientId,
}) => companionProof(
  secret,
  companionTranscript(
    label: label,
    mode: mode,
    nonce: nonce,
    tvKey: tvKey,
    clientKey: clientKey,
    clientId: clientId,
  ),
);

/// Derives the remembered-client token from an ECDH secret. Both sides compute
/// it, so it never crosses the wire. Matches CompanionReceiver.pairingToken.
String companionPairingToken(String shared, String nonce, String clientId) =>
    companionProof(shared, 'zangetsu-token|$nonce|$clientId');

/// Ephemeral P-256 key used once per pairing, matching the Kotlin receiver's
/// encoding: the public key is an uncompressed point in lowercase hex.
class CompanionKey {
  CompanionKey._(this._private, this.publicHex);

  /// Generates a fresh key pair from the platform's secure random source.
  factory CompanionKey.generate() {
    final seed = Uint8List.fromList(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final generator = pc.ECKeyGenerator()
      ..init(
        pc.ParametersWithRandom(
          pc.ECKeyGeneratorParameters(_curve),
          pc.FortunaRandom()..seed(pc.KeyParameter(seed)),
        ),
      );
    final pair = generator.generateKeyPair();
    return CompanionKey._fromPrivate(pair.privateKey as pc.ECPrivateKey);
  }

  /// Rebuilds a key from its private scalar; used by interoperability tests.
  @visibleForTesting
  factory CompanionKey.fromPrivateHex(String hex) => CompanionKey._fromPrivate(
    pc.ECPrivateKey(BigInt.parse(hex, radix: 16), _curve),
  );

  /// Derives the public point from [key] and wraps both halves.
  factory CompanionKey._fromPrivate(pc.ECPrivateKey key) {
    final point = (_curve.G * key.d)!;
    return CompanionKey._(key, _hex(point.getEncoded(false)));
  }

  /// NIST P-256 (secp256r1), the curve the Kotlin receiver uses.
  static final _curve = pc.ECCurve_secp256r1();
  /// P-256 field prime, used to check that a peer point lies on the curve.
  static final _p = BigInt.parse(
    'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
    radix: 16,
  );
  /// P-256 curve coefficient b in y^2 = x^3 - 3x + b.
  static final _b = BigInt.parse(
    '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
    radix: 16,
  );
  /// Shape of a valid public key on the wire: uncompressed '04' prefix + X + Y.
  static final pattern = RegExp(r'^04[0-9a-f]{128}$');

  /// Private scalar; never leaves this object.
  final pc.ECPrivateKey _private;

  /// Uncompressed public point: "04" + X + Y, 130 lowercase hex characters.
  final String publicHex;

  /// Returns the shared X coordinate as 64 hex characters.
  /// Throws [FormatException] when [peerHex] is not a valid P-256 point.
  String shared(String peerHex) {
    if (!pattern.hasMatch(peerHex)) throw const FormatException('Invalid key');
    final x = BigInt.parse(peerHex.substring(2, 66), radix: 16);
    final y = BigInt.parse(peerHex.substring(66), radix: 16);
    // Reject points off the curve (invalid-curve attack); a = -3 on P-256.
    if (x >= _p ||
        y >= _p ||
        (y * y - (x * x * x - BigInt.from(3) * x + _b)) % _p != BigInt.zero)
      throw const FormatException('Invalid key');
    final peer = pc.ECPublicKey(_curve.curve.createPoint(x, y), _curve);
    final secret = (pc.ECDHBasicAgreement()..init(_private)).calculateAgreement(
      peer,
    );
    return secret.toRadixString(16).padLeft(64, '0');
  }

  /// Encodes [bytes] as lowercase hex, two characters per byte.
  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Compares complete proofs without returning early on a differing character.
bool companionProofMatches(String a, String b) {
  var difference = a.length ^ b.length;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ (i < b.length ? b.codeUnitAt(i) : 0);
  }
  return difference == 0;
}

/// Phone-side transport to the TV: one JSON object per newline-terminated UTF-8
/// line, frames capped at 256 KiB, the same protocol the Android receiver
/// speaks. Commands run one at a time and carry an increasing `id` that the
/// reply must echo. Closing a failed exchange is intentional: uncertain
/// commands are not replayed.
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
  /// Connected TCP socket to the TV; owned and destroyed by this wire.
  final Socket socket;

  /// Decoded incoming frames, paused and resumed with the socket.
  final _frames = StreamController<Map<String, dynamic>>();

  /// Bytes of the line received so far, before its newline arrives.
  final _buffer = <int>[];

  /// Pull-style reader over [_frames] used by [read].
  late final StreamIterator<Map<String, dynamic>> _reader;

  /// False once [close] has run; no more frames are sent or delivered.
  bool alive = true;

  /// Last command ID sent by [exchange].
  int _sequence = 0;

  /// End of the exchange queue, so commands never overlap on the socket.
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
  /// The `state` poll waits 4 s for its reply, other actions 90 s.
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
