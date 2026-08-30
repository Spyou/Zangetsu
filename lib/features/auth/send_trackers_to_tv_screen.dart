import 'package:flutter/material.dart';

import '../../core/anilist/anilist_service.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/mal_service.dart';
import '../../core/tracker/relay/tracker_relay.dart';
import '../../core/tracker/relay/tracker_relay_crypto.dart';
import '../../core/tracker/simkl_service.dart';
import '../../core/tracker/tracker.dart';
import 'tv_pairing_service.dart';
import '../../l10n/l10n.dart';

/// Phone: after scanning a TV's trackers-only QR, pick which connected trackers
/// to relay (connecting a missing one first if desired), then send.
class SendTrackersToTvScreen extends StatefulWidget {
  const SendTrackersToTvScreen({super.key, required this.code, required this.nonce});
  final String? code;
  final String? nonce;

  static Route<void> route(String? code, String? nonce) => MaterialPageRoute(
      builder: (_) => SendTrackersToTvScreen(code: code, nonce: nonce));

  @override
  State<SendTrackersToTvScreen> createState() => _SendTrackersToTvScreenState();
}

class _SendTrackersToTvScreenState extends State<SendTrackersToTvScreen> {
  // No labels here: [initState] reads this list, and resolving translations
  // needs an inherited widget lookup, which isn't allowed until initState has
  // finished. Labels come from [_labelFor] at build time instead.
  late final _rows = <({String id, Tracker t})>[
    (id: 'anilist', t: sl<AniListService>()),
    (id: 'mal', t: sl<MalService>()),
    (id: 'simkl', t: sl<SimklService>()),
  ];

  String _labelFor(String id, AppLocalizations l10n) => switch (id) {
    'anilist' => l10n.anilist,
    'mal' => l10n.myAnimeList,
    _ => l10n.simkl,
  };
  final _selected = <String>{};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final r in _rows) {
      if (r.t.isConnected) _selected.add(r.id);
    }
  }

  Future<void> _connect(Tracker t) async {
    setState(() => _busy = true);
    await t.connect();
    if (!mounted) return;
    setState(() {
      _busy = false;
      for (final r in _rows) {
        if (r.t.isConnected) _selected.add(r.id);
      }
    });
  }

  Future<void> _send() async {
    final code = widget.code, nonce = widget.nonce;
    if (code == null || nonce == null || _selected.isEmpty) {
      setState(() => _error = context.l10n.pickAtLeastOneTracker);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final packed = sl<TrackerRelay>().pack(only: _selected);
      final blob = TrackerRelayCrypto.encrypt(packed.encode(), nonce);
      final ok = await sl<TvPairingService>()
          .approve(code, trackerBlob: blob, trackersOnly: true);
      if (!mounted) return;
      setState(() => _busy = false);
      if (ok) {
        Navigator.of(context).maybePop();
      } else {
        setState(() => _error = context.l10n.sendFailedTryAgain);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = context.l10n.sendFailedTryAgain;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(context.l10n.sendTrackers), backgroundColor: AppColors.bg),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.chooseTrackersToSend, style: AppText.headline),
            const SizedBox(height: 16),
            for (final r in _rows)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_labelFor(r.id, context.l10n), style: AppText.body),
                trailing: r.t.isConnected
                    ? Checkbox(
                        value: _selected.contains(r.id),
                        onChanged: (v) => setState(() =>
                            v == true ? _selected.add(r.id) : _selected.remove(r.id)),
                      )
                    : TextButton(
                        onPressed: _busy ? null : () => _connect(r.t),
                        child: Text(context.l10n.connect),
                      ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: AppText.caption.copyWith(color: Colors.redAccent)),
            ],
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _send,
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    padding: const EdgeInsets.symmetric(vertical: 15)),
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(context.l10n.sendToTV, style: AppText.headline.copyWith(color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
