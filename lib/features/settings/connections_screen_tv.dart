import 'package:flutter/material.dart';

import '../../core/anilist/anilist_service.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/mal_service.dart';
import '../../core/tracker/simkl_service.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../auth/tv_tracker_connect_screen.dart';

/// TV-native tracker Connections: each of AniList / MAL / Simkl with its status
/// and a D-pad Connect (per-tracker relay QR) / Disconnect (local-only).
class ConnectionsScreenTv extends StatefulWidget {
  const ConnectionsScreenTv({super.key});

  @override
  State<ConnectionsScreenTv> createState() => _ConnectionsScreenTvState();
}

class _ConnectionsScreenTvState extends State<ConnectionsScreenTv> {
  late final _rows = <({String id, String label, Tracker t})>[
    (id: 'anilist', label: 'AniList', t: sl<AniListService>()),
    (id: 'mal', label: 'MyAnimeList', t: sl<MalService>()),
    (id: 'simkl', label: 'Simkl', t: sl<SimklService>()),
  ];

  Future<void> _connect(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => TvTrackerConnectScreen(trackerId: id)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _disconnect(Tracker t) async {
    await t.disconnect();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        automaticallyImplyLeading: false,
        title: Text('Connections', style: AppText.headline),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.separated(
              clipBehavior: Clip.none,
              padding: const EdgeInsets.fromLTRB(40, 8, 40, 40),
              itemCount: _rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 14),
              itemBuilder: (context, i) {
                final r = _rows[i];
                final connected = r.t.isConnected;
                final who = connected
                    ? (r.t.viewerName != null ? 'Connected as ${r.t.viewerName}' : 'Connected')
                    : 'Not connected';
                return TvListFocusable(
                  autofocus: i == 0,
                  semanticLabel: '${r.label}, $who',
                  onTap: () => connected ? _disconnect(r.t) : _connect(r.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.label,
                                style: AppText.headline.copyWith(fontSize: 17),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                who,
                                style: AppText.caption.copyWith(
                                  color: connected
                                      ? AppColors.textSecondary
                                      : AppColors.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          connected ? 'Disconnect' : 'Connect',
                          style: AppText.body.copyWith(
                            color: connected
                                ? Colors.redAccent
                                : AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
            child: Text(
              'Disconnecting here only signs this tracker out on the TV — your phone stays connected.',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
