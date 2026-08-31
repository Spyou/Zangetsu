// About: version, updates, support and the developer credits.
part of 'settings_screen.dart';


// ---------------------------------------------------------------------------
// About
// ---------------------------------------------------------------------------

class AboutSettingsScreen extends StatefulWidget {
  const AboutSettingsScreen({super.key});

  @override
  State<AboutSettingsScreen> createState() => _AboutSettingsScreenState();
}

class _AboutSettingsScreenState extends State<AboutSettingsScreen> {
  static const String _websiteUrl = 'https://zangetsu.online';
  static const String _telegramUrl = 'https://t.me/+9mQlsdvDlo83Mjk1';
  static const String _discordUrl = kDiscordInviteUrl;
  static const String _githubUrl = 'https://github.com/Spyou/Zangetsu';

  final UpdateService _updateService = UpdateService();
  bool _betaUpdates = false;

  @override
  void initState() {
    super.initState();
    _updateService.betaOptIn().then((v) {
      if (mounted) setState(() => _betaUpdates = v);
    });
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  void _push(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.about),
      body: ListView(
        padding: const EdgeInsets.only(top: 24, bottom: 30),
        children: [
          const _ProfileCard(),
          const SizedBox(height: 24),
          // Contributors — above Social, opens the full list.
          SettingsCard(
            children: [
              SettingsTile(
                autofocus: true,
                icon: Icons.group_rounded,
                title: context.l10n.contributors,
                onTap: () => _push(const ContributorsScreen()),
              ),
            ],
          ),
          SettingsSectionLabel(context.l10n.social, muted: true),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.language_rounded,
                title: context.l10n.website,
                subtitle: 'zangetsu.online',
                onTap: () => _open(_websiteUrl),
              ),
              SettingsTile(
                icon: Icons.send_rounded,
                title: context.l10n.telegram,
                subtitle: context.l10n.communityChat,
                onTap: () => _open(_telegramUrl),
              ),
              SettingsTile(
                icon: Icons.discord,
                title: context.l10n.discord,
                subtitle: context.l10n.joinTheServer,
                onTap: () => _open(_discordUrl),
              ),
              SettingsTile(
                icon: Icons.code_rounded,
                title: context.l10n.github,
                subtitle: context.l10n.viewTheSourceCode,
                onTap: () => _open(_githubUrl),
              ),
            ],
          ),
          SettingsSectionLabel(context.l10n.appSection, muted: true),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.help_outline_rounded,
                title: context.l10n.howItWorks,
                subtitle: context.l10n.howItWorksSubtitle,
                onTap: () => _push(const HowItWorksScreen()),
              ),
              SettingsTile(
                icon: Icons.system_update_rounded,
                title: context.l10n.checkForUpdates,
                subtitle: context.l10n.checkForUpdatesSubtitle,
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.checkingForUpdates)),
                  );
                  maybeShowUpdateDialog(context, manual: true);
                },
              ),
              SettingsTile(
                icon: Icons.science_outlined,
                title: context.l10n.betaUpdates,
                subtitle: context.l10n.betaUpdatesSubtitle,
                subtitleMaxLines: null,
                trailing: Switch.adaptive(
                  value: _betaUpdates,
                  activeThumbColor: AppColors.accent,
                  onChanged: (v) async {
                    // Turning it on: confirm first so it's never a silent opt-in.
                    if (v && !await confirmJoinBeta(context)) return;
                    await _updateService.setBetaOptIn(v);
                    if (!mounted) return;
                    setState(() => _betaUpdates = v);
                    // Then check right away so a waiting beta shows up.
                    if (v && context.mounted) {
                      maybeShowUpdateDialog(context, manual: true);
                    }
                  },
                ),
              ),
              SettingsTile(
                icon: Icons.favorite_border_rounded,
                title: context.l10n.supportTheApp,
                subtitle: context.l10n.buyMeACoffee,
                onTap: () => _push(const DonateScreen()),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '© ${DateTime.now().year}  $kAppName',
              style: AppText.caption.copyWith(
                color: AppColors.textTertiary,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The app header: the clean logo mark, name and version floating on the page
/// (no grey box), then the lead-developer card.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 6),
        Image.asset('assets/icon/logo_mark.png', height: 96),
        const SizedBox(height: 16),
        Text(kAppName, style: AppText.largeTitle.copyWith(fontSize: 25)),
        const SizedBox(height: 3),
        Text(
          'v$kAppVersion',
          style: AppText.caption.copyWith(color: AppColors.textTertiary),
        ),
        const SizedBox(height: 20),
        const _DeveloperRow(),
      ],
    );
  }
}

/// The "Developer" row inside the profile card.
class _DeveloperRow extends StatelessWidget {
  const _DeveloperRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            final uri = Uri.parse('https://github.com/spyou');
            if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
              await launchUrl(uri, mode: LaunchMode.platformDefault);
            }
          },
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              // One solid dark grey, matching the app's cards.
              color: AppColors.settingsCard,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const TeamAvatar(
                  url: 'https://github.com/spyou.png?size=200',
                  name: 'Krishna',
                  size: 46,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Krishna Vishwakarma',
                        style: AppText.headline.copyWith(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.l10n.leadDeveloper,
                        style: AppText.caption.copyWith(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.code_rounded, color: AppColors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
