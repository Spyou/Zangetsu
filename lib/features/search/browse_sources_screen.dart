import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import 'browse_source_screen.dart';
import 'browse_sources_list.dart';

/// Entry point for browsing installed sources without disturbing Home's
/// active source, reached from Home's header action while in Sources mode
/// (see `HomeBrowseSourcesAction`) — picking a source pushes the existing
/// [BrowseSourceScreen], same as it did as Search's idle state.
///
/// The field at the top filters this list by source name only — it never
/// touches content search.
class BrowseSourcesScreen extends StatefulWidget {
  const BrowseSourcesScreen({super.key});

  @override
  State<BrowseSourcesScreen> createState() => _BrowseSourcesScreenState();
}

class _BrowseSourcesScreenState extends State<BrowseSourcesScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(context.l10n.sources, style: AppText.headline),
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
            child: BrowseSourcesList(
              query: _query,
              onBrowse: (id, name) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => BrowseSourceScreen(sourceId: id, title: name),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
