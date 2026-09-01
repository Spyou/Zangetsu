import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../home/search_screen.dart';
import 'browse_source_screen.dart';
import 'browse_sources_list.dart';
import 'browse_sources_screen_tv.dart';

/// Entry point for browsing installed sources without disturbing Home's
/// active source, reached from Home's header action while Z Mode is on (see
/// `HomeBrowseSourcesAction`) — picking a source pushes the existing
/// [BrowseSourceScreen], same as it did as Search's idle state.
///
/// Kind tabs (Streaming / Manga / Novel) narrow [BrowseSourcesList] to one
/// bucket group; the field above them filters by source name within
/// whichever tab is selected. The search action in the app bar is a
/// different thing entirely — it's content search fanned out across every
/// installed source (see [SearchScreen.forceSources]), the replacement for
/// the all-sources search that left the main Search screen when Z Mode is on.
class BrowseSourcesScreen extends StatefulWidget {
  const BrowseSourcesScreen({super.key});

  @override
  State<BrowseSourcesScreen> createState() => _BrowseSourcesScreenState();
}

class _BrowseSourcesScreenState extends State<BrowseSourcesScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  String _query = '';
  late final TabController _tab = TabController(length: 3, vsync: this);

  /// [SourceListKind] and [ContentMode] both split streaming/manga/novel the
  /// same way; this just names the mapping for [SearchScreen.forceMode].
  ContentMode _modeOf(SourceListKind kind) => switch (kind) {
    SourceListKind.streaming => ContentMode.anime,
    SourceListKind.manga => ContentMode.manga,
    SourceListKind.novel => ContentMode.novel,
  };

  @override
  void dispose() {
    _controller.dispose();
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const BrowseSourcesScreenTv();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(context.l10n.sources, style: AppText.headline),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: context.l10n.search,
            // forceMode: the tab this was opened from, so the search fans out
            // over that tab's sources instead of Home's global content mode —
            // see [SearchScreen.forceMode].
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SearchScreen(
                  forceSources: true,
                  forceMode: _modeOf(SourceListKind.values[_tab.index]),
                ),
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          // Drop the default full-width hairline under the bar — same
          // treatment as History's tabs.
          dividerColor: Colors.transparent,
          dividerHeight: 0,
          indicatorSize: TabBarIndicatorSize.label,
          indicator: UnderlineTabIndicator(
            borderRadius: const BorderRadius.all(Radius.circular(2)),
            borderSide: BorderSide(width: 3, color: AppColors.accent),
            insets: const EdgeInsets.symmetric(horizontal: -6),
          ),
          labelColor: AppColors.accent,
          unselectedLabelColor: AppColors.textSecondary,
          overlayColor: WidgetStateProperty.all(Colors.transparent),
          tabs: [
            Tab(text: context.l10n.modeStreaming),
            Tab(text: context.l10n.modeManga),
            Tab(text: context.l10n.modeNovel),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  const Icon(Icons.search, size: 20, color: AppColors.textTertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      onChanged: (v) => setState(() => _query = v),
                      style: AppText.body.copyWith(color: AppColors.textPrimary),
                      cursorColor: AppColors.accent,
                      decoration: InputDecoration(
                        hintText: context.l10n.searchSources,
                        hintStyle: AppText.body,
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  if (_query.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textTertiary),
                      tooltip: context.l10n.clear,
                      onPressed: () => setState(() {
                        _controller.clear();
                        _query = '';
                      }),
                    )
                  else
                    const SizedBox(width: 12),
                ],
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                for (final k in SourceListKind.values)
                  BrowseSourcesList(
                    kind: k,
                    query: _query,
                    onBrowse: (id, name) => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => BrowseSourceScreen(sourceId: id, title: name),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
