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
class BrowseSourcesScreen extends StatelessWidget {
  const BrowseSourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(context.l10n.sources, style: AppText.headline),
      ),
      body: BrowseSourcesList(
        onBrowse: (id, name) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => BrowseSourceScreen(sourceId: id, title: name),
          ),
        ),
      ),
    );
  }
}
