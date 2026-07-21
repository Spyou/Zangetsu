import 'dart:convert';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase/supabase_service.dart';

/// Result of a TV-side poll.
class PairPoll {
  const PairPoll.pending()
      : approved = false,
        appSecret = null,
        trackerBlob = null;
  const PairPoll.approved(this.appSecret, this.trackerBlob) : approved = true;
  final bool approved;
  final String? appSecret;
  final String? trackerBlob;
}

/// TV ↔ phone device pairing over Supabase (Netflix/Hotstar "activate" pattern).
///
/// The signed-OUT TV registers a `pending` `tv_pairings` row (RLS permits a
/// pending insert and nothing else), shows a QR + short code, and polls the
/// `pair-tv` Edge Function until the signed-in phone approves — then trades the
/// minted one-time token for a real session via [completeSignIn]. Reads of the
/// login secret are gated by the TV-generated `tv_secret`, so seeing the code
/// alone can't steal the session.
class TvPairingService {
  TvPairingService(this._sb);
  final SupabaseService _sb;

  SupabaseClient get _c => _sb.client;
  static const _pairTtlMs = 5 * 60 * 1000; // 5 minutes

  // ── TV side ────────────────────────────────────────────────────────────────

  /// Register a pending pairing. Returns the human code (also embedded in the
  /// QR) and the TV-only secret that gates collecting the login token in [poll].
  Future<({String code, String tvSecret})> startPairing(String deviceName) async {
    final code = _randomCode(8);
    final tvSecret = _randomToken(32);
    await _c.from('tv_pairings').insert({
      'code': code,
      'tv_secret': tvSecret,
      'status': 'pending',
      'device_name': deviceName,
      'expires_at': DateTime.now().millisecondsSinceEpoch + _pairTtlMs,
    });
    return (code: code, tvSecret: tvSecret);
  }

  /// Poll for approval. Pending until the phone approves; then the minted
  /// one-time `appSecret` (a token hash) + optional tracker blob.
  Future<PairPoll> poll(String code, String tvSecret) async {
    final data = await _invoke({'action': 'poll', 'code': code, 'tvSecret': tvSecret});
    if (data['ok'] != true || data['status'] != 'approved') {
      return const PairPoll.pending();
    }
    return PairPoll.approved(data['appSecret'] as String?, data['trackerBlob'] as String?);
  }

  /// Exchange the minted token hash for a real session — no email needed, the
  /// token hash carries the identity. Returns null on success, else a short
  /// message to surface on-screen.
  Future<String?> completeSignIn(String appSecret) async {
    try {
      final res = await _c.auth.verifyOTP(tokenHash: appSecret, type: OtpType.magiclink);
      if (res.session != null && _c.auth.currentUser != null) return null;
      return "Couldn't complete sign-in. Get a new code and try again.";
    } on AuthException catch (e) {
      return e.message;
    } catch (_) {
      return "Couldn't complete sign-in. Get a new code and try again.";
    }
  }

  // ── Phone side ───────────────────────────────────────────────────────────────

  /// The TV's device name for a pending code, so the user sees what they approve.
  /// null if not found / expired.
  Future<String?> lookup(String code) async {
    try {
      final data = await _invoke({'action': 'info', 'code': _norm(code)});
      return data['ok'] == true ? data['deviceName'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  /// Approve the pairing (signed-in phone). The Edge Function reads the phone's
  /// identity from the auth header the client attaches automatically.
  Future<bool> approve(String code) async {
    final data = await _invoke({'action': 'approve', 'code': _norm(code)});
    return data['ok'] == true;
  }

  // ── helpers ──────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    final res = await _c.functions.invoke('pair-tv', body: body);
    final d = res.data;
    if (d is Map) return d.cast<String, dynamic>();
    if (d is String && d.isNotEmpty) {
      return (jsonDecode(d) as Map).cast<String, dynamic>();
    }
    return const {};
  }

  static String _norm(String code) => code.trim().toUpperCase();

  static final _rng = Random.secure();
  // No 0/O/1/I — a code the user may read off the screen and type on a phone.
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  String _randomCode(int n) => String.fromCharCodes(
        List.generate(n, (_) => _alphabet.codeUnitAt(_rng.nextInt(_alphabet.length))),
      );
  String _randomToken(int n) =>
      base64Url.encode(List<int>.generate(n, (_) => _rng.nextInt(256))).substring(0, n);
}
