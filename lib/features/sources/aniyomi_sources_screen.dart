import 'dart:io';
import 'package:watch_app/core/hive/safe_box.dart';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../core/aniyomi/aniyomi_extension_service.dart';
import '../../core/aniyomi/aniyomi_provider.dart';
import '../../core/aniyomi/aniyomi_repo.dart';
import '../../core/aniyomi/aniyomi_update.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/i18n/source_languages.dart';
import '../../core/prefs/source_lang_prefs.dart';
import '../../core/provider/base_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/states.dart';
import 'aniyomi_repo_tab.dart' show kAniyomiReposBoxName, AniyomiAddRepoDialog, AniyomiRepoTab;
import 'source_language_sheet.dart';
import 'sources_search_field.dart';

part 'aniyomi_sources_screen_phone.dart';
part 'aniyomi_sources_screen_tv.dart';

/// Dedicated Aniyomi ecosystem screen — Installed + Repositories in one
/// scroll. Stateful because it owns the Aniyomi-repos Hive-box state
/// (relocated from the old `_SourcesViewState`/`_TvSourcesViewState`).
///
/// Phone and TV share this file (`if (sl<AppMode>().isTv)`); every lifted
/// widget below is copied byte-identical from `sources_screen.dart` /
/// `sources_screen_tv.dart` / `aniyomi_repo_tab.dart` — only the host screen
/// around them is new. Aniyomi sources have NO enable/disable switch — a tap
/// sets the source active, matching the original screens exactly. Aniyomi
/// itself is Android-only: the TV view returns an early "not available"
/// screen off Android (mirroring the old TV screen's `Platform.isAndroid`
/// guard around this whole section); the phone view has no such guard,
/// matching the original phone tab.
class AniyomiSourcesScreen extends StatefulWidget {
  const AniyomiSourcesScreen({super.key});

  @override
  State<AniyomiSourcesScreen> createState() => _AniyomiSourcesScreenState();
}

class _AniyomiSourcesScreenState extends State<AniyomiSourcesScreen> {
  // ── Aniyomi repo state (moved from _SourcesViewState) ─────────────────────
  List<String> _aniyomiRepoUrls = [];

  @override
  void initState() {
    super.initState();
    _loadAniyomiRepos();
  }

  Future<void> _loadAniyomiRepos() async {
    if (!Hive.isBoxOpen(kAniyomiReposBoxName)) {
      await openBoxSafely<String>(kAniyomiReposBoxName);
    }
    final box = Hive.box<String>(kAniyomiReposBoxName);
    if (mounted) setState(() => _aniyomiRepoUrls = box.values.toList());
  }

  Future<void> _addAniyomiRepo(String url) async {
    if (!Hive.isBoxOpen(kAniyomiReposBoxName)) {
      await openBoxSafely<String>(kAniyomiReposBoxName);
    }
    final box = Hive.box<String>(kAniyomiReposBoxName);
    if (box.values.contains(url)) return;
    await box.add(url);
    if (mounted) setState(() => _aniyomiRepoUrls = box.values.toList());
  }

  Future<void> _removeAniyomiRepo(String url) async {
    if (!Hive.isBoxOpen(kAniyomiReposBoxName)) return;
    final box = Hive.box<String>(kAniyomiReposBoxName);
    final key = box.toMap().entries
        .where((e) => e.value == url)
        .map((e) => e.key)
        .firstOrNull;
    if (key != null) await box.delete(key);
    if (mounted) setState(() => _aniyomiRepoUrls = box.values.toList());
  }

  /// Shows the add-repo dialog and, on a chosen URL, persists it directly.
  /// This is a State method (not a free function) so it calls
  /// [_addAniyomiRepo] on `this`.
  Future<void> _showAddAniyomiRepoDialog(BuildContext context) async {
    final Set<String> alreadyAdded = {};
    if (Hive.isBoxOpen(kAniyomiReposBoxName)) {
      alreadyAdded.addAll(Hive.box<String>(kAniyomiReposBoxName).values);
    }
    final url = await showDialog<String>(
      context: context,
      builder: (_) => AniyomiAddRepoDialog(alreadyAddedUrls: alreadyAdded),
    );
    if (url == null || url.isEmpty) return;
    await _addAniyomiRepo(url);
  }

  Future<void> _showAddAniyomiRepoDialogTv() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _AniScreenTvAddRepoDialog(),
    );
    if (url == null || url.isEmpty) return;
    if (!mounted) return;
    await _addAniyomiRepo(url);
  }

  @override
  Widget build(BuildContext context) {
    return sl<AppMode>().isTv
        ? _AniScreenTvView(
            repoUrls: _aniyomiRepoUrls,
            onAddRepo: _showAddAniyomiRepoDialogTv,
            onRemoveRepo: _removeAniyomiRepo,
          )
        : _AniScreenPhoneView(
            repoUrls: _aniyomiRepoUrls,
            onAddRepo: () => _showAddAniyomiRepoDialog(context),
            onRemoveRepo: _removeAniyomiRepo,
          );
  }
}
