import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../core/aniyomi/aniyomi_extension_service.dart';
import '../../core/aniyomi/aniyomi_provider.dart';
import '../../core/aniyomi/aniyomi_update.dart';
import '../../core/provider/base_provider.dart';
import '../../core/di/injector.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'providers_hub_screen.dart';

/// Thin entry point for the Providers screen — delegates to
/// [ProvidersHubScreen], which routes to a dedicated screen per ecosystem
/// (Zangetsu / CloudStream / Aniyomi). Kept as a stable public class since
/// Settings and other callers push `const SourcesScreen()`.
class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ProvidersHubScreen();
  }
}

// ---------------------------------------------------------------------------
// Aniyomi installed group (Installed tab — item 0)
// ---------------------------------------------------------------------------

/// Aniyomi providers installed via `.apk` extensions, shown at the top of the
/// Installed tab. Reads from [AniyomiManager] (a [ChangeNotifier]). Hidden when
/// none are installed. Each provider row lets the user set it as the active
/// source; there's no enable/disable toggle (all Aniyomi sources are always on).
class _AniyomiInstalledGroup extends StatefulWidget {
  const _AniyomiInstalledGroup();

  @override
  State<_AniyomiInstalledGroup> createState() => _AniyomiInstalledGroupState();
}

class _AniyomiInstalledGroupState extends State<_AniyomiInstalledGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sl<AniyomiManager>(),
      builder: (context, _) {
        final sources = sl<AniyomiManager>().all;
        if (sources.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: _expanded ? 0 : -0.25,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(
                        Icons.expand_more,
                        color: AppColors.textTertiary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'ANIYOMI',
                        style: AppText.overline.copyWith(
                          color: AppColors.textTertiary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${sources.length}',
                      style: AppText.overline.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: !_expanded
                  ? const SizedBox(width: double.infinity)
                  : BlocBuilder<ActiveSourceCubit, String>(
                      builder: (context, activeId) => Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          children: [
                            for (var i = 0; i < sources.length; i++) ...[
                              if (i > 0)
                                const Divider(
                                  height: 0.5,
                                  thickness: 0.5,
                                  color: AppColors.hairline,
                                ),
                              _AniSourceRow(
                                source: sources[i],
                                activeId: activeId,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 18),
          ],
        );
      },
    );
  }
}

/// Single Aniyomi source row in the Installed tab. Tapping makes it the active
/// source. No enable/disable switch — Aniyomi sources are always active.
class _AniSourceRow extends StatefulWidget {
  const _AniSourceRow({
    required this.source,
    required this.activeId,
    this.updateLookupFn,
    this.applyUpdateFn,
  });

  final BaseProvider source;
  final String activeId;

  /// Test seam: overrides the live `AniyomiManager.updateFor` lookup. When
  /// non-null the button also skips the `AnimatedBuilder` so widget tests
  /// stay deterministic.
  final AniyomiUpdate? Function(String pkg)? updateLookupFn;

  /// Test seam: overrides the real install-from-repo apply flow.
  final Future<void> Function(AniyomiUpdate update)? applyUpdateFn;

  @override
  State<_AniSourceRow> createState() => _AniSourceRowState();
}

class _AniSourceRowState extends State<_AniSourceRow> {
  bool _hasSettings = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _checkSettings();
  }

  @override
  void didUpdateWidget(_AniSourceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The element may be recycled for a different source when the list is
    // filtered/reordered (e.g. the NSFW toggle) — re-query so the gear
    // reflects the source now shown rather than a stale cached result.
    if (oldWidget.source.sourceId != widget.source.sourceId) {
      _hasSettings = false;
      _checkSettings();
    }
  }

  Future<void> _checkSettings() async {
    final src = widget.source;
    if (src is! AniyomiProvider) return;
    final has = await AniyomiExtensionService().hasSourceSettings(src.info.id);
    if (mounted) setState(() => _hasSettings = has);
  }

  Future<void> _openSettings() async {
    final src = widget.source;
    if (src is! AniyomiProvider) return;
    await AniyomiExtensionService().openSourceSettings(src.info.id);
  }

  /// Shows a confirm dialog then uninstalls the source.
  Future<void> _confirmUninstall(BuildContext context) async {
    final name = widget.source.displayName;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Uninstall $name?', style: AppText.headline),
        content: Text(
          'This removes the source from your installed list.',
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Uninstall',
              style: AppText.body.copyWith(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final aniProvider =
        widget.source is AniyomiProvider ? widget.source as AniyomiProvider : null;
    final pkg = aniProvider?.info.pkg;

    const boxName = 'aniyomi_installed';
    if (pkg != null && Hive.isBoxOpen(boxName)) {
      final box = Hive.box<dynamic>(boxName);
      final apkPath = box.get(pkg) as String?;
      if (apkPath != null) {
        try {
          final f = File(apkPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      await box.delete(pkg);
    }

    if (pkg != null) {
      sl<AniyomiManager>().removeWhere(
        (p) => p is AniyomiProvider && p.info.pkg == pkg,
      );
    } else {
      sl<AniyomiManager>().removeWhere(
        (p) => p.sourceId == widget.source.sourceId,
      );
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Uninstalled $name')));
    }
  }

  Future<void> _applyUpdate(AniyomiUpdate update) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final apply = widget.applyUpdateFn ?? _defaultApplyUpdate;
      await apply(update);
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Updated ${update.name}')));
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _defaultApplyUpdate(AniyomiUpdate update) async {
    // installFromRepo never throws — it returns an empty list on failure —
    // so a failed download must be surfaced here rather than silently
    // reported as a success that clears the update badge.
    final providers = await AniyomiExtensionService()
        .installFromRepo(update.entry, manager: sl<AniyomiManager>());
    if (providers.isEmpty) throw Exception('Update failed to install');
    sl<AniyomiManager>().clearUpdatesForPkg(update.pkg);
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final active = source.sourceId == widget.activeId;
    final lang = source is AniyomiProvider ? source.info.lang : '';
    final nameColor = active ? AppColors.accent : AppColors.textPrimary;
    final aniProvider = source is AniyomiProvider ? source : null;
    final lookup = widget.updateLookupFn ??
        (String pkg) => sl<AniyomiManager>().updateFor(pkg);

    Widget updateButton() {
      final pkg = aniProvider?.info.pkg;
      final update = pkg == null ? null : lookup(pkg);
      if (update == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: FilledButton(
          onPressed: _busy ? null : () => _applyUpdate(update),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            elevation: 0,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text('Update → v${update.availableVersion}'),
        ),
      );
    }

    return InkWell(
      onTap: () {
        context.read<ActiveSourceCubit>().setSource(source.sourceId);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text('Active source: ${source.displayName}')),
          );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.displayName,
                    style: AppText.headline.copyWith(
                      fontSize: 15,
                      color: nameColor,
                      fontWeight: active ? FontWeight.w600 : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    lang.isNotEmpty ? 'aniyomi • $lang' : 'aniyomi',
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
            if (widget.updateLookupFn != null)
              updateButton()
            else
              AnimatedBuilder(
                animation: sl<AniyomiManager>(),
                builder: (_, _) => updateButton(),
              ),
            if (_hasSettings)
              IconButton(
                tooltip: 'Source settings',
                icon: const Icon(Icons.tune_rounded, size: 20),
                color: AppColors.textSecondary,
                onPressed: _openSettings,
              ),
            IconButton(
              tooltip: 'Uninstall',
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              color: AppColors.textSecondary,
              onPressed: () => _confirmUninstall(context),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared CloudStream repo recommendations
// ---------------------------------------------------------------------------

/// One-tap CloudStream repos surfaced in the "Add CS repo" dialog (see
/// [CloudStreamSourcesScreen]). Each is added through the same
/// [CloudStreamManager.addRepo] path as a manually pasted URL.
const List<({String name, String desc, String url})> kRecommendedCsRepos = [
  (
    name: 'Phisher',
    desc: 'Large multi-source pack — anime, movies & series',
    url: 'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
  ),
  (
    name: 'CNC (All Languages)',
    desc: 'Multi-language movies, series & live TV',
    url: 'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
  ),
];

/// Test-only handle to the private installed Aniyomi row.
@visibleForTesting
Widget debugAniSourceRow({
  required BaseProvider source,
  required String activeId,
  AniyomiUpdate? Function(String pkg)? updateLookupFn,
  Future<void> Function(AniyomiUpdate update)? applyUpdateFn,
}) =>
    _AniSourceRow(
      source: source,
      activeId: activeId,
      updateLookupFn: updateLookupFn,
      applyUpdateFn: applyUpdateFn,
    );
