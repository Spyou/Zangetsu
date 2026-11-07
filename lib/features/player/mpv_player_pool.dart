import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// Prepares one unused player. Played sessions are always disposed, never reused.
class MpvPlayerPool {
  MpvPlayerPool({Player Function(bool libass)? createPlayer})
    : _createPlayer = createPlayer ?? _newPlayer;

  final Player Function(bool libass) _createPlayer;
  Player? _warm;
  bool? _warmLibass;

  Player acquire({required bool libass}) {
    final warm = _warm;
    final matches = _warmLibass == libass;
    _warm = null;
    _warmLibass = null;
    if (warm != null) {
      if (matches) return warm;
      unawaited(_discard(warm));
    }
    return _createPlayer(libass);
  }

  void warmUp({required bool libass}) {
    if (_warm != null) return;
    try {
      _warm = _createPlayer(libass);
      _warmLibass = libass;
    } catch (_) {
      // Preparation is optional; acquire still creates a fresh player.
    }
  }

  Future<void> clear() async {
    final warm = _warm;
    _warm = null;
    _warmLibass = null;
    if (warm != null) await _discard(warm);
  }

  Future<void> _discard(Player player) async {
    try {
      await player.dispose();
    } catch (_) {
      // Failure to discard unused preparation must not interrupt navigation.
    }
  }

  static Player _newPlayer(bool libass) => Player(
    configuration: PlayerConfiguration(
      libass: libass,
      libassAndroidFont: 'assets/fonts/NotoSans-Regular.ttf',
      libassAndroidFontName: 'Noto Sans',
    ),
  );
}
