import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Carries a single search result into its destination route.
class SettingsSearchTarget extends InheritedWidget {
  SettingsSearchTarget({super.key, required String title, required super.child})
    : _match = _SearchMatch(title);

  final _SearchMatch _match;

  static SettingsSearchTarget? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsSearchTarget>();

  static Widget reveal(
    BuildContext context,
    String title,
    Widget Function(FocusNode?) buildRow, {
    bool focus = false,
  }) {
    final match = _of(context)?._match;
    if (match == null || title != match.title) return buildRow(null);
    return _SearchReveal(match: match, focus: focus, buildRow: buildRow);
  }

  @override
  bool updateShouldNotify(SettingsSearchTarget oldWidget) =>
      _match != oldWidget._match;
}

class _SearchMatch {
  _SearchMatch(this.title);

  final String title;
  bool revealed = false;
}

/// Search destinations lay out their finite row list eagerly so a match can
/// be revealed even when it starts outside the viewport.
class SettingsSearchList extends StatelessWidget {
  const SettingsSearchList({
    super.key,
    required this.children,
    this.padding,
    this.clipBehavior = Clip.hardEdge,
    this.scrollDirection = Axis.vertical,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final Clip clipBehavior;
  final Axis scrollDirection;

  @override
  Widget build(BuildContext context) => ListView(
    padding: padding,
    clipBehavior: clipBehavior,
    scrollDirection: scrollDirection,
    children: SettingsSearchTarget._of(context) == null
        ? children
        : [
            if (scrollDirection == Axis.vertical)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
          ],
  );
}

class _SearchReveal extends StatefulWidget {
  const _SearchReveal({
    required this.match,
    required this.focus,
    required this.buildRow,
  });

  final _SearchMatch match;
  final bool focus;
  final Widget Function(FocusNode?) buildRow;

  @override
  State<_SearchReveal> createState() => _SearchRevealState();
}

class _SearchRevealState extends State<_SearchReveal> {
  late final FocusNode? _focusNode = widget.focus ? FocusNode() : null;
  bool _highlighted = false;
  Timer? _clearHighlight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  Future<void> _reveal() async {
    if (!mounted || widget.match.revealed) return;
    widget.match.revealed = true;
    await Scrollable.ensureVisible(
      context,
      alignment: 0.35,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    _focusNode?.requestFocus();
    setState(() => _highlighted = true);
    _clearHighlight = Timer(
      const Duration(milliseconds: 1000),
      () => setState(() => _highlighted = false),
    );
  }

  @override
  void dispose() {
    _clearHighlight?.cancel();
    _focusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    key: const ValueKey('settings-search-highlight'),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260),
    foregroundDecoration: BoxDecoration(
      color: _highlighted
          ? AppColors.accent.withValues(alpha: 0.18)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
    ),
    child: widget.buildRow(_focusNode),
  );
}
