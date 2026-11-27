import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_alert_dialog.dart' show TvFocusClaim;
import '../../core/tv/tv_focusable.dart';
import '../../core/update/update_service.dart';
import '../../l10n/l10n.dart';

/// Check for an update and, if one exists, show the update dialog.
///
/// In [manual] mode (the Settings "Check for updates" tap) it also tells the
/// user when they're already up to date. In auto mode (app launch) it stays
/// silent unless a newer, non-skipped release is found — so it never nags.
Future<void> maybeShowUpdateDialog(
  BuildContext context, {
  bool manual = false,
}) async {
  final service = UpdateService();
  final info = await service.checkForUpdate(respectSkip: !manual);
  if (!context.mounted) return;
  if (info == null) {
    if (manual) {
      final v = await service.currentVersion();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.onLatestVersion(v.isEmpty ? '' : ' (v$v)'),
          ),
        ),
      );
    }
    return;
  }
  await showUpdateDialog(context, info: info, service: service);
}

bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

/// Shows the update dialog for a known [info]. On TV it opens on the root
/// navigator with a closed focus loop (like `showTvAlertDialog`), so the
/// D-pad cannot walk the screen underneath. The phone look is unchanged.
Future<void> showUpdateDialog(
  BuildContext context, {
  required UpdateInfo info,
  required UpdateService service,
}) {
  final tv = _isTv;
  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    requestFocus: tv ? true : null,
    traversalEdgeBehavior: tv ? TraversalEdgeBehavior.closedLoop : null,
    builder: (_) => _UpdateDialog(info: info, service: service),
  );
}

/// Confirmation shown when the user flips the "Beta updates" switch on, so it's
/// never a silent opt-in. Returns true if they chose to join.
Future<bool> confirmJoinBeta(BuildContext context) async {
  final tv = _isTv;
  final joined = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    requestFocus: tv ? true : null,
    traversalEdgeBehavior: tv ? TraversalEdgeBehavior.closedLoop : null,
    builder: (ctx) => _TvDialogFocus(
      enabled: tv,
      builder: (nodes) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.science_outlined, color: AppColors.accent, size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(ctx.l10n.joinBetaUpdates, style: AppText.title),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                ctx.l10n.joinBetaUpdatesBody,
                style: AppText.body.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _tvButton(
                      tv: tv,
                      node: nodes.secondary,
                      autofocus: true,
                      onTap: () => Navigator.of(ctx).pop(false),
                      child: TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: Text(
                          ctx.l10n.notNow,
                          style: AppText.button.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    _tvButton(
                      tv: tv,
                      node: nodes.primary,
                      onTap: () => Navigator.of(ctx).pop(true),
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                        ),
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: Text(
                          ctx.l10n.joinBeta,
                          style: AppText.button.copyWith(color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return joined ?? false;
}

/// On TV, wraps a dialog button in a [TvFocusable] with a white focus ring,
/// so the D-pad can see and pick it. The Material button inside keeps its look
/// but is kept out of focus, so each button is one D-pad stop. Phones get
/// [child] unchanged.
Widget _tvButton({
  required bool tv,
  required FocusNode node,
  required VoidCallback onTap,
  required Widget child,
  bool autofocus = false,
}) {
  if (!tv) return child;
  return TvFocusable(
    focusNode: node,
    autofocus: autofocus,
    scale: 1.0,
    borderRadius: 20,
    onTap: onTap,
    child: ExcludeFocus(child: child),
  );
}

/// Focus nodes a TV dialog hands to its buttons. [secondary] is the default
/// (the decline), [primary] the confirm, [tertiary] an extra decline.
class _DialogNodes {
  final FocusNode secondary = FocusNode(debugLabel: 'dialog-secondary');
  final FocusNode primary = FocusNode(debugLabel: 'dialog-primary');
  final FocusNode tertiary = FocusNode(debugLabel: 'dialog-tertiary');

  void dispose() {
    secondary.dispose();
    primary.dispose();
    tertiary.dispose();
  }
}

/// Owns a dialog's button nodes and, on TV, keeps D-pad focus on them with
/// [TvFocusClaim] (the default decline first; Skip / Later hide while a
/// download runs, so the claim falls through to Update).
class _TvDialogFocus extends StatefulWidget {
  const _TvDialogFocus({required this.enabled, required this.builder});

  final bool enabled;
  final Widget Function(_DialogNodes nodes) builder;

  @override
  State<_TvDialogFocus> createState() => _TvDialogFocusState();
}

class _TvDialogFocusState extends State<_TvDialogFocus> {
  final _DialogNodes _nodes = _DialogNodes();

  @override
  void dispose() {
    _nodes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(_nodes);
    if (!widget.enabled) return child;
    return TvFocusClaim(
      targets: [_nodes.secondary, _nodes.primary, _nodes.tertiary],
      child: child,
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info, required this.service});

  final UpdateInfo info;
  final UpdateService service;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress; // null until the download starts
  bool _busy = false; // downloading or installing
  String? _error;

  Future<void> _skip() async {
    await widget.service.skipVersion(widget.info.version);
    if (mounted) Navigator.of(context).pop();
  }

  void _later() => Navigator.of(context).pop();

  Future<void> _startUpdate() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
    });
    try {
      final file = await widget.service.downloadApk(
        widget.info.apkUrl,
        expectedSize: widget.info.apkSize,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _progress = 1);
      final ok = await widget.service.installApk(file);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(); // installer launched — close the dialog
      } else {
        setState(() {
          _busy = false;
          _error = context.l10n.couldnTOpenInstaller;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _error = context.l10n.downloadFailedCheckConnection;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tv = _isTv;
    return _TvDialogFocus(
      enabled: tv,
      builder: (nodes) => _buildDialog(context, tv, nodes),
    );
  }

  Widget _buildDialog(BuildContext context, bool tv, _DialogNodes nodes) {
    final notes = widget.info.notes;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.system_update_rounded,
                  color: AppColors.accent,
                  size: 26,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.info.isPrerelease
                        ? context.l10n.betaUpdateAvailable
                        : context.l10n.updateAvailable,
                    style: AppText.title,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Version ${widget.info.version}',
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
            const SizedBox(height: 14),
            if (notes.isNotEmpty) ...[
              Text(context.l10n.whatSNew, style: AppText.caption),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: _ReleaseNotes(notes),
                ),
              ),
              const SizedBox(height: 14),
            ],
            if (_progress != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 6,
                  backgroundColor: AppColors.surface2,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _progress! >= 1
                    ? context.l10n.startingInstaller
                    : context.l10n.downloadingPercent((_progress! * 100).round()),
                style: AppText.caption,
              ),
              const SizedBox(height: 8),
            ],
            if (_error != null) ...[
              Text(
                _error!,
                style: AppText.caption.copyWith(color: AppColors.accent),
              ),
              const SizedBox(height: 8),
            ],
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (!_busy)
                    _tvButton(
                      tv: tv,
                      node: nodes.tertiary,
                      onTap: _skip,
                      child: TextButton(
                        onPressed: _skip,
                        child: Text(
                          context.l10n.skip,
                          style: AppText.button.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  if (!_busy)
                    _tvButton(
                      tv: tv,
                      node: nodes.secondary,
                      // Later is the safe default: OK on open never installs
                      // and never skips a version for good.
                      autofocus: true,
                      onTap: _later,
                      child: TextButton(
                        onPressed: _later,
                        child: Text(
                          context.l10n.later,
                          style: AppText.button.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  _tvButton(
                    tv: tv,
                    node: nodes.primary,
                    onTap: () {
                      if (!_busy) _startUpdate();
                    },
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                      ),
                      onPressed: _busy ? null : _startUpdate,
                      child: Text(
                        _error != null
                            ? context.l10n.retry
                            : context.l10n.update,
                        style: AppText.button.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders GitHub release notes (markdown) as clean styled text — no markdown
/// package needed. Handles the common changelog subset: `#`/`##`/`###` headers,
/// `-`/`*`/`+` bullets, `**bold**`/`__bold__`, `*italic*`/`_italic_`,
/// `` `code` ``, `[text](url)` links (shown as their text), `---` rules, and
/// blank-line spacing. Soft-wrapped lines inside a paragraph/bullet are merged
/// first, so an inline span (e.g. `**bold**`) that wraps across a source newline
/// still renders. Anything it doesn't recognise falls through as plain text.
class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes(this.source);

  final String source;

  @override
  Widget build(BuildContext context) {
    final base = AppText.body.copyWith(
      color: AppColors.textSecondary,
      height: 1.4,
    );
    final widgets = <Widget>[];
    for (final b in _blocks(source)) {
      switch (b.type) {
        case 'blank':
          widgets.add(const SizedBox(height: 8));
        case 'hr':
          widgets.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Divider(
              color: AppColors.textTertiary.withValues(alpha: 0.3),
              height: 1,
            ),
          ));
        case 'header':
          widgets.add(Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Text.rich(_inline(
              b.text,
              base.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: b.level <= 1 ? 16 : (b.level == 2 ? 15 : 14),
              ),
            )),
          ));
        case 'bullet':
          widgets.add(Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: base),
                Expanded(child: Text.rich(_inline(b.text, base))),
              ],
            ),
          ));
        default:
          widgets.add(Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text.rich(_inline(b.text, base)),
          ));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }

  /// Group the markdown into logical blocks, merging soft-wrapped continuation
  /// lines into the preceding paragraph/bullet so inline spans that wrap across
  /// source newlines aren't split (which would leak literal `**` markers).
  List<_Blk> _blocks(String src) {
    final out = <_Blk>[];
    for (final raw in src.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) {
        out.add(_Blk('blank'));
      } else if (RegExp(r'^([-*_])\1{2,}$').hasMatch(line)) {
        out.add(_Blk('hr'));
      } else if (RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line) case final h?) {
        out.add(_Blk('header', h.group(2)!, h.group(1)!.length));
      } else if (RegExp(r'^[-*+]\s+(.*)$').firstMatch(line) case final b?) {
        out.add(_Blk('bullet', b.group(1)!));
      } else if (out.isNotEmpty &&
          (out.last.type == 'bullet' || out.last.type == 'p')) {
        out.last.text = '${out.last.text} $line'; // soft-wrap continuation
      } else {
        out.add(_Blk('p', line));
      }
    }
    return out;
  }

  /// Inline markdown → styled spans: `**bold**`/`__bold__`, `*italic*`/`_italic_`,
  /// `` `code` ``, and `[text](url)` links collapsed to their text.
  TextSpan _inline(String text, TextStyle style) {
    final delinked = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
      (m) => m.group(1) ?? '',
    );
    final spans = <TextSpan>[];
    final pattern = RegExp(r'(\*\*|__)(.+?)\1|(\*|_)(.+?)\3|`([^`]+)`');
    var i = 0;
    for (final m in pattern.allMatches(delinked)) {
      if (m.start > i) {
        spans.add(TextSpan(text: delinked.substring(i, m.start), style: style));
      }
      if (m.group(2) != null) {
        spans.add(TextSpan(
          text: m.group(2),
          style: style.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ));
      } else if (m.group(4) != null) {
        spans.add(TextSpan(
          text: m.group(4),
          style: style.copyWith(fontStyle: FontStyle.italic),
        ));
      } else if (m.group(5) != null) {
        spans.add(TextSpan(
          text: m.group(5),
          style: style.copyWith(fontFamily: 'monospace', color: Colors.white),
        ));
      }
      i = m.end;
    }
    if (i < delinked.length) {
      spans.add(TextSpan(text: delinked.substring(i), style: style));
    }
    return TextSpan(children: spans, style: style);
  }
}

/// One logical markdown block: type ∈ {blank, hr, header, bullet, p}.
class _Blk {
  _Blk(this.type, [this.text = '', this.level = 0]);
  final String type;
  String text;
  final int level;
}
