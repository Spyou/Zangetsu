import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/di/injector.dart';
import '../../core/share/pair_link.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/relay/tracker_blob.dart';
import '../../core/tracker/relay/tracker_relay.dart';
import '../../core/tracker/relay/tracker_relay_crypto.dart';
import 'tv_pairing_service.dart';

class TvTrackerConnectScreen extends StatefulWidget {
  const TvTrackerConnectScreen({super.key, required this.trackerId});
  final String trackerId; // 'anilist' | 'mal' | 'simkl'

  @override
  State<TvTrackerConnectScreen> createState() => _TvTrackerConnectScreenState();
}

class _TvTrackerConnectScreenState extends State<TvTrackerConnectScreen> {
  final _svc = sl<TvPairingService>();
  String? _code, _tvSecret, _nonce, _error;
  Timer? _poll;

  String get _label => switch (widget.trackerId) {
        'anilist' => 'AniList',
        'mal' => 'MyAnimeList',
        'simkl' => 'Simkl',
        _ => widget.trackerId,
      };

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final r = await _svc.startPairing('TV · $_label');
      if (!mounted) return;
      setState(() {
        _code = r.code;
        _tvSecret = r.tvSecret;
        _nonce = r.nonce;
      });
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't start. Try again.");
    }
  }

  Future<void> _tick() async {
    if (_code == null) return;
    PairPoll res;
    try {
      res = await _svc.poll(_code!, _tvSecret!);
    } catch (_) {
      return;
    }
    if (!res.approved || !mounted) return;
    _poll?.cancel();
    final ok = await _apply(res.trackerBlob);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).maybePop(true);
    } else {
      setState(() => _error = "Couldn't read the tracker. Try again.");
    }
  }

  Future<bool> _apply(String? blob) async {
    final nonce = _nonce;
    if (blob == null || blob.isEmpty || nonce == null) return false;
    try {
      final json = TrackerRelayCrypto.decrypt(blob, nonce);
      final applied = await sl<TrackerRelay>().unpack(TrackerBlob.decode(json));
      return applied.contains(widget.trackerId);
    } catch (_) {
      return false;
    }
  }

  Widget _qrOption({
    required String data,
    required String title,
    required String subtitle,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: QrImageView(data: data, size: 200, gapless: true),
        ),
        const SizedBox(height: 14),
        Text(title, style: AppText.title),
        const SizedBox(height: 4),
        Text(subtitle,
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: AppColors.textSecondary)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Connect $_label', style: AppText.headline),
      ),
      body: Center(
        child: _code == null
            ? (_error != null
                ? Text(_error!, style: AppText.body)
                : const CircularProgressIndicator())
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // QR 1 — phone-app relay. HTTPS so iPhone Camera treats
                      // it as a link (custom schemes show "No usable data
                      // found"). The /pair/ page then opens the app, which
                      // approves and relays this $_label session to the TV.
                      _qrOption(
                        data: PairLink.qrData(
                          code: _code!,
                          nonce: _nonce,
                          trackers: true,
                        ),
                        title: 'Have the app?',
                        subtitle: 'Open Zangetsu on your\nphone and scan',
                      ),
                      const SizedBox(width: 36),
                      // QR 2 — no app needed. Opens a web page that runs the
                      // $_label login in the phone's browser and relays the token
                      // to this TV (same encrypted-blob path the poll consumes).
                      _qrOption(
                        data: 'https://zangetsu.online/tv-connect/'
                            '?code=$_code&nonce=$_nonce&tracker=${widget.trackerId}',
                        title: 'No app?',
                        subtitle: 'Scan to log in with\n$_label in your browser',
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!,
                        style:
                            AppText.caption.copyWith(color: Colors.redAccent)),
                  ],
                ],
              ),
      ),
    );
  }
}
