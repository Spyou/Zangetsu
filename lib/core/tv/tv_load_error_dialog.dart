import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';

import '../../features/sources/providers_hub_screen.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';
import '../mode/content_mode.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'tv_focusable.dart';
import 'tv_playback_failure.dart';

/// Inserts a blocking loading overlay while play-time source resolution runs.
/// Returns a dismiss callback — call it in a `finally` block.
VoidCallback showTvPlaybackLoadingOverlay(
  BuildContext context, {
  String? message,
}) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => Material(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 52,
              height: 52,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            if (message != null && message.isNotEmpty) ...[
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 96),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(
                    fontSize: 20,
                    height: 1.4,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
  overlay.insert(entry);
  return () {
    if (entry.mounted) entry.remove();
  };
}

/// TV-sized alert when an episode stream fails to resolve or start.
Future<void> showTvPlaybackLoadError(
  BuildContext context, {
  TvPlaybackLoadFailure failure = const TvPlaybackLoadFailure(
    TvPlaybackLoadFailureKind.generic,
  ),
}) {
  debugPrint(
    '[tv-dialog] showTvPlaybackLoadError · kind=${failure.kind} '
    'mode=${failure.mode}',
  );
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => _TvPlaybackLoadErrorDialog(failure: failure),
  );
}

class _TvPlaybackLoadErrorDialog extends StatelessWidget {
  const _TvPlaybackLoadErrorDialog({required this.failure});

  final TvPlaybackLoadFailure failure;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mode = failure.mode ?? ContentMode.anime;

    late final String title;
    late final String body;
    late final String primaryLabel;
    late final VoidCallback onPrimary;
    final showCancel =
        failure.kind == TvPlaybackLoadFailureKind.noSourcesInstalled;

    switch (failure.kind) {
      case TvPlaybackLoadFailureKind.noSourcesInstalled:
        title = l10n.noModeSourcesYet(contentModeLabel(l10n, mode));
        body = l10n.addSourceFromProvidersHint(
          contentModeContentNoun(l10n, mode),
        );
        primaryLabel = l10n.browseSources;
        onPrimary = () {
          Navigator.pop(context);
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ProvidersHubScreen(),
            ),
          );
        };
      case TvPlaybackLoadFailureKind.noSourceMatch:
        title = l10n.noSourceHasThisYet;
        body =
            'None of your installed sources have this title. Try another source '
            'from the detail screen, or install more in Providers.';
        primaryLabel = l10n.ok;
        onPrimary = () => Navigator.pop(context);
      case TvPlaybackLoadFailureKind.episodeNotAvailable:
        title = "Couldn't load this episode";
        body = l10n.noSourcesFoundForThisEpisode;
        primaryLabel = l10n.ok;
        onPrimary = () => Navigator.pop(context);
      case TvPlaybackLoadFailureKind.generic:
        title = "Couldn't load this episode";
        body =
            'There was an issue loading this content. If this continues, '
            'try changing sources.';
        primaryLabel = l10n.ok;
        onPrimary = () => Navigator.pop(context);
    }

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 96, vertical: 64),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 560, maxWidth: 680),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 36, 40, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppText.largeTitle.copyWith(fontSize: 28),
              ),
              const SizedBox(height: 16),
              Text(
                body,
                style: AppText.body.copyWith(
                  fontSize: 18,
                  height: 1.45,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (showCancel)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: TvFocusable(
                        variant: TvFocusVariant.pill,
                        onTap: () => Navigator.pop(context),
                        semanticLabel: l10n.cancel,
                        builder: (focused) => DecoratedBox(
                          decoration: BoxDecoration(
                            color: focused
                                ? Colors.white24
                                : AppColors.surface2,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: focused
                                  ? Colors.white54
                                  : AppColors.hairline,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 14,
                            ),
                            child: Text(
                              l10n.cancel,
                              style: AppText.headline.copyWith(fontSize: 18),
                            ),
                          ),
                        ),
                      ),
                    ),
                  TvFocusable(
                    autofocus: true,
                    variant: TvFocusVariant.pill,
                    onTap: onPrimary,
                    semanticLabel: primaryLabel,
                    builder: (focused) => DecoratedBox(
                      decoration: BoxDecoration(
                        color: focused ? Colors.white : AppColors.accent,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 36,
                          vertical: 14,
                        ),
                        child: Text(
                          primaryLabel,
                          style: AppText.headline.copyWith(
                            fontSize: 18,
                            color: focused ? Colors.black : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Symbolic result of the TV playback-error dialog.
enum TvPlaybackErrorAction {
  /// Re-run resolution — the failed source was already marked unhealthy so a
  /// re-resolve sweeps to the next candidate.
  tryNext,

  /// Open the source picker so the user can pick a specific source.
  selectSource,

  /// Just close — do nothing.
  close,
}

/// TV dialog shown when the native ExoPlayer reports a fatal playback error
/// AFTER a source resolved successfully (e.g. PARSING_CONTAINER_NOT_SUPPORTED).
/// The stream was playable in theory but the container/decoder rejected it, so
/// re-running resolution with a different source is the sensible recovery.
Future<TvPlaybackErrorAction> showTvPlaybackErrorDialog(
  BuildContext context, {
  required String errorCode,
  required String showTitle,
}) async {
  debugPrint(
    '[tv-dialog] showTvPlaybackErrorDialog · code=$errorCode show=$showTitle',
  );
  final result = await showDialog<TvPlaybackErrorAction>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => _TvPlaybackErrorDialog(
      errorCode: errorCode,
      showTitle: showTitle,
    ),
  );
  return result ?? TvPlaybackErrorAction.close;
}

class _TvPlaybackErrorDialog extends StatelessWidget {
  const _TvPlaybackErrorDialog({
    required this.errorCode,
    required this.showTitle,
  });

  final String errorCode;
  final String showTitle;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 96, vertical: 64),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 560, maxWidth: 680),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 36, 40, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Couldn't play this source",
                style: AppText.largeTitle.copyWith(fontSize: 28),
              ),
              const SizedBox(height: 16),
              Text(
                '$showTitle failed to play. The stream was found but the '
                'player couldn\'t decode it${errorCode.isNotEmpty ? " ($errorCode)" : ""}. '
                'Try another source, or pick one manually.',
                style: AppText.body.copyWith(
                  fontSize: 18,
                  height: 1.45,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _ErrorActionButton(
                    label: 'Close',
                    autofocus: false,
                    onTap: () =>
                        Navigator.pop(context, TvPlaybackErrorAction.close),
                  ),
                  const SizedBox(width: 12),
                  _ErrorActionButton(
                    label: 'Select Source',
                    autofocus: false,
                    onTap: () => Navigator.pop(
                      context,
                      TvPlaybackErrorAction.selectSource,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _ErrorActionButton(
                    label: 'Try Next Source',
                    autofocus: true,
                    accent: true,
                    onTap: () => Navigator.pop(
                      context,
                      TvPlaybackErrorAction.tryNext,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorActionButton extends StatelessWidget {
  const _ErrorActionButton({
    required this.label,
    required this.onTap,
    this.autofocus = false,
    this.accent = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool autofocus;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      variant: TvFocusVariant.pill,
      onTap: onTap,
      semanticLabel: label,
      builder: (focused) => DecoratedBox(
        decoration: BoxDecoration(
          color: focused
              ? (accent ? Colors.white : Colors.white24)
              : (accent ? AppColors.accent : AppColors.surface2),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          child: Text(
            label,
            style: AppText.headline.copyWith(
              fontSize: 18,
              color: focused ? Colors.black : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
