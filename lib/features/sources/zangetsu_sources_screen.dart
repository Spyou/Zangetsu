import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/provider/provider_repo_registry.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_action_chip.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/tv/tv_text_field.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/ui/states.dart';
import 'bloc/sources_bloc.dart';
import 'bloc/sources_event.dart';
import 'bloc/sources_state.dart';
import 'source_settings_screen.dart';
import 'sources_search_field.dart';
import '../../l10n/l10n.dart';

part 'zangetsu_sources_screen_phone.dart';
part 'zangetsu_sources_screen_tv.dart';

/// Dedicated Zangetsu (JS provider) ecosystem screen — Installed and
/// Repositories as two tabs. Self-contained: creates its own [SourcesBloc]
/// so it works whether pushed standalone or from the Providers hub.
///
/// Phone and TV share this file (`if (sl<AppMode>().isTv)`); every lifted
/// widget below is copied byte-identical from `sources_screen.dart` /
/// `sources_screen_tv.dart` — only the host screen around them is new.
class ZangetsuSourcesScreen extends StatelessWidget {
  const ZangetsuSourcesScreen({
    super.key,
    this.openToRepos = false,
    this.scopeToReading = false,
  });

  /// Opens straight to the Repositories tab (phone only — TV keeps its own
  /// default) — used by the reading-mode source picker's install CTA, which
  /// has nothing to show on Installed anyway.
  final bool openToRepos;

  /// When true, the phone Installed tab leads with manga/novel providers
  /// instead of the full unfiltered list, with a "Show all" toggle back to
  /// everything (Task E3 fix round 1 — a tile that opens an identical
  /// unfiltered screen doesn't read as "different from streaming mode").
  /// Defaults to false so every other call site (the existing Zangetsu row,
  /// Settings → Providers) is untouched. TV never reads this — [_ZTvView]
  /// doesn't take it, so TV is unaffected regardless of the caller.
  final bool scopeToReading;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => SourcesBloc(
        registry: sl<ProviderRegistry>(),
        repos: sl<ProviderReposRegistry>(),
      ),
      child: sl<AppMode>().isTv
          ? const _ZTvView()
          : _ZPhoneView(
              openToRepos: openToRepos,
              scopeToReading: scopeToReading,
            ),
    );
  }
}
