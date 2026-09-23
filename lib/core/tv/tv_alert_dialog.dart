import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../di/injector.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'tv_focusable.dart';

/// One action in a [TvAlertDialog].
class TvAlertAction {
  const TvAlertAction({
    required this.label,
    required this.onTap,
    this.primary = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onTap;

  /// Accent fill (OK / confirm). Secondary actions stay surface-tinted.
  final bool primary;

  /// Land D-pad focus here when the dialog opens. Set on the default action
  /// so the remote cannot wander onto the route underneath.
  final bool autofocus;
}

/// TV-first alert chrome — same look as the playback load-error popup.
///
/// [AlertDialog] + [TextButton] leave D-pad focus on the screen below and
/// do not handle OK/Select the way [TvFocusable] does. Use this (or
/// [showTvAlertDialog]) for any blocking confirm / result dialog.
class TvAlertDialog extends StatefulWidget {
  const TvAlertDialog({
    super.key,
    required this.title,
    required this.body,
    required this.actions,
  });

  final String title;

  /// Dialog copy. Wrapped in the shared body style, so a [Text] or [Column]
  /// of [Text]s is enough.
  final Widget body;

  final List<TvAlertAction> actions;

  @override
  State<TvAlertDialog> createState() => _TvAlertDialogState();
}

class _TvAlertDialogState extends State<TvAlertDialog> {
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'tv-alert-scope');
  late final List<FocusNode> _actionNodes;

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  int get _autofocusIndex {
    final i = widget.actions.indexWhere((a) => a.autofocus);
    return i >= 0 ? i : 0;
  }

  @override
  void initState() {
    super.initState();
    _actionNodes = [
      for (final action in widget.actions)
        FocusNode(debugLabel: 'tv-alert-${action.label}'),
    ];
    if (_isTv && widget.actions.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _claim());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _claim());
      });
    }
  }

  void _claim() {
    if (!mounted || _actionNodes.isEmpty) return;
    final node = _actionNodes[_autofocusIndex];
    if (node.canRequestFocus) node.requestFocus();
  }

  void _onScopeFocus(bool has) {
    // A Settings tile (or the TV content scope) can steal primary focus after
    // we first land. Pull it back so D-pad cannot walk the route underneath.
    if (!has && mounted && _isTv) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _claim());
    }
  }

  @override
  void dispose() {
    _scope.dispose();
    for (final n in _actionNodes) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tv = _isTv || MediaQuery.sizeOf(context).width >= 600;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: tv
          ? const EdgeInsets.symmetric(horizontal: 96, vertical: 64)
          : const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: FocusScope(
        node: _scope,
        onFocusChange: _onScopeFocus,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: tv ? 560 : 0,
            maxWidth: tv ? 680 : 400,
            maxHeight: MediaQuery.sizeOf(context).height * 0.75,
          ),
          child: Padding(
            padding: tv
                ? const EdgeInsets.fromLTRB(40, 36, 40, 28)
                : const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: tv
                      ? AppText.largeTitle.copyWith(fontSize: 28)
                      : AppText.title,
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: SingleChildScrollView(
                    child: DefaultTextStyle.merge(
                      style: AppText.body.copyWith(
                        fontSize: tv ? 18 : 15,
                        height: 1.45,
                        color: AppColors.textSecondary,
                      ),
                      child: widget.body,
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (var i = 0; i < widget.actions.length; i++)
                        _TvAlertButton(
                          action: widget.actions[i],
                          isTv: tv,
                          focusNode: _actionNodes[i],
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
  }
}

/// [showDialog] wrapper that always dims the barrier like the TV popups.
///
/// Pushed on the **root** navigator. Settings-on-TV hosts leaves in a nested
/// navigator inside the shell's content [FocusScopeNode]; a local dialog stays
/// in that scope, so autofocus is ignored (a tile already holds focus) and
/// D-pad keeps walking the screen underneath.
Future<T?> showTvAlertDialog<T>(
  BuildContext context, {
  required String title,
  required Widget body,
  required List<TvAlertAction> actions,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black54,
    barrierDismissible: barrierDismissible,
    useRootNavigator: true,
    requestFocus: true,
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    builder: (_) => TvAlertDialog(title: title, body: body, actions: actions),
  );
}

/// Shared by the button fill and the [TvFocusable] outline so the ring hugs
/// the chrome instead of painting a tighter pill on top.
const _kActionRadius = 24.0;

class _TvAlertButton extends StatelessWidget {
  const _TvAlertButton({
    required this.action,
    required this.isTv,
    required this.focusNode,
  });

  final TvAlertAction action;
  final bool isTv;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final pad = EdgeInsets.symmetric(
      horizontal: isTv
          ? (action.primary ? 36 : 28)
          : (action.primary ? 24 : 20),
      vertical: isTv ? 14 : 12,
    );
    final Color bg = action.primary ? AppColors.accent : AppColors.surface2;
    final Color fg = Colors.white;

    Widget chrome(bool focused) {
      // Outline only — the box variant also tints and drop-shadows, which
      // reads as a wash over these filled pills.
      final borderColor = focused
          ? Colors.white
          : (action.primary ? Colors.transparent : AppColors.hairline);
      return DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(_kActionRadius),
          border: Border.all(color: borderColor, width: 2.5),
        ),
        child: Padding(
          padding: pad,
          child: Text(
            action.label,
            style: AppText.headline.copyWith(
              fontSize: isTv ? 18 : 16,
              color: fg,
            ),
          ),
        ),
      );
    }

    if (!isTv) {
      return GestureDetector(onTap: action.onTap, child: chrome(false));
    }
    return TvFocusable(
      focusNode: focusNode,
      autofocus: action.autofocus,
      variant: TvFocusVariant.none,
      onTap: action.onTap,
      semanticLabel: action.label,
      builder: chrome,
    );
  }
}
