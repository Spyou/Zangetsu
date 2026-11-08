/// One episode's live timeline, independent of watched-history updates.
class SimklPlaybackSession {
  SimklPlaybackSession(this._send);

  final void Function(String action, double progress) _send;
  bool _started = false;
  bool _playing = false;
  bool _stopped = false;
  int _positionMs = 0;
  int _lastSentMs = 0;
  double _progress = 0;

  void update({
    required int positionMs,
    required int durationMs,
    required bool playing,
    bool completed = false,
  }) {
    if (_stopped || durationMs <= 0 || positionMs < 0) return;
    // Natural ticks move ~10s (native heartbeat); only a bigger jump is a seek.
    final sought = (positionMs - _positionMs).abs() > 15000;
    _positionMs = positionMs;
    _progress =
        ((positionMs / durationMs * 100).clamp(0.0, 100.0) * 100).round() / 100;
    if (completed) {
      stop();
      return;
    }
    if (!_started && !playing) return;
    var sent = false;
    if (playing && (!_started || !_playing || sought)) {
      _send('start', _progress);
      _started = true;
      sent = true;
    } else if (!playing && _playing) {
      _send('pause', _progress);
      sent = true;
    } else if (playing && positionMs - _lastSentMs >= 30000) {
      // Steady playback: refresh the tracker every 30 seconds so its
      // "now watching" progress moves instead of freezing at the start.
      _send('start', _progress);
      sent = true;
    }
    if (sent) _lastSentMs = positionMs;
    _playing = playing;
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    if (_started) _send('stop', _progress);
  }
}
