// Tracker connections: AniList, MyAnimeList, Simkl.
part of 'settings_screen.dart';


// ---------------------------------------------------------------------------
// Connections (trackers)
// ---------------------------------------------------------------------------

/// Lists the trackers (AniList / MyAnimeList / Simkl); each opens its own
/// connect/disconnect screen.
class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  @override
  Widget build(BuildContext context) {
    final trackers = <Tracker>[
      sl<AniListService>(),
      sl<MalService>(),
      sl<SimklService>(),
    ];
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Connections'),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          SettingsCard(
            children: [
              for (final t in trackers)
                SettingsTile(
                  icon: Icons.sync_alt_rounded,
                  title: t.displayName,
                  subtitle: t.isConnected
                      ? (t.viewerName ?? 'Connected')
                      : 'Sync progress as you watch',
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TrackerSettingsScreen(tracker: t),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              'Sync watch progress and list status to your accounts. Anime syncs '
              'to all three; movies and series sync to Simkl.',
              style: AppText.caption,
            ),
          ),
        ],
      ),
    );
  }
}
