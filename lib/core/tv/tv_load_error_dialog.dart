import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';

import '../../features/sources/providers_hub_screen.dart';
import '../../l10n/l10n.dart';
import '../../l10n/ui_strings.dart';
import '../mode/content_mode.dart';
import '../theme/app_text.dart';
import 'tv_alert_dialog.dart';
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
            MaterialPageRoute<void>(builder: (_) => const ProvidersHubScreen()),
          );
        };
      case TvPlaybackLoadFailureKind.noSourceMatch:
        // When a source never actually answered, "none of them have this" is a
        // verdict we haven't earned — say what happened instead.
        title = failure.detail == null
            ? l10n.checkedTopSources
            : "Couldn't check every source";
        body =
            failure.detail ??
            'None of your installed sources have this title. Try another source '
                'from the detail screen, or install more in Providers.';
        primaryLabel = l10n.ok;
        onPrimary = () => Navigator.pop(context);
      case TvPlaybackLoadFailureKind.episodeNotAvailable:
        title = failure.detail == null
            ? "Couldn't load this episode"
            : "Couldn't check every source";
        body = failure.detail ?? l10n.noSourcesFoundForThisEpisode;
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

    return TvAlertDialog(
      title: title,
      body: Text(body),
      actions: [
        if (showCancel)
          TvAlertAction(
            label: l10n.cancel,
            onTap: () => Navigator.pop(context),
          ),
        TvAlertAction(
          label: primaryLabel,
          primary: true,
          autofocus: true,
          onTap: onPrimary,
        ),
      ],
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
    builder: (ctx) =>
        _TvPlaybackErrorDialog(errorCode: errorCode, showTitle: showTitle),
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
    return TvAlertDialog(
      title: "Couldn't play this source",
      body: Text(
        '$showTitle failed to play. The stream was found but the '
        'player couldn\'t decode it${errorCode.isNotEmpty ? " ($errorCode)" : ""}. '
        'Try another source, or pick one manually.',
      ),
      actions: [
        TvAlertAction(
          label: 'Close',
          onTap: () => Navigator.pop(context, TvPlaybackErrorAction.close),
        ),
        TvAlertAction(
          label: 'Select Source',
          onTap: () =>
              Navigator.pop(context, TvPlaybackErrorAction.selectSource),
        ),
        TvAlertAction(
          label: 'Try Next Source',
          primary: true,
          autofocus: true,
          onTap: () => Navigator.pop(context, TvPlaybackErrorAction.tryNext),
        ),
      ],
    );
  }
}
