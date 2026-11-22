import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'tv_keys.dart';

/// A [TextField] that stays D-pad navigable on Android TV.
///
/// Autofocusing a normal [TextField] raises the leanback IME, which swallows
/// D-pad events so the remote cannot move to the next control. [EditableText]
/// also eats arrow keys for cursor movement even when the IME is closed.
///
/// This widget keeps **two** focus targets on the same field:
///  * a navigation [Focus] that autofocus / D-pad land on (no IME)
///  * the [TextField]'s own focus node, which stays editable and only receives
///    focus on OK / tap — that focus-gain is what raises the leanback keyboard.
///    (Flipping `readOnly` + [TextInput.show] is cancelled on many TVs.)
///
/// Use anywhere on TV in place of a bare [TextField].
class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration,
    this.autofocus = false,
    this.enabled = true,
    this.obscureText = false,
    this.obscuringCharacter = '•',
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.inputFormatters,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.style,
    this.cursorColor,
    this.onChanged,
    this.onSubmitted,
  });

  /// Optional external **navigation** focus node (D-pad landing, no IME).
  /// Pass one only when a parent needs to [FocusNode.requestFocus] the field
  /// chrome without opening the keyboard.
  final FocusNode? focusNode;

  final TextEditingController? controller;
  final InputDecoration? decoration;
  final bool autofocus;
  final bool enabled;
  final bool obscureText;
  final String obscuringCharacter;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final bool autocorrect;
  final bool enableSuggestions;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLines;
  final int? minLines;
  final int? maxLength;
  final TextStyle? style;
  final Color? cursorColor;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  /// Native backup when the framework's TextInput.show is cancelled on TV.
  static const _imeChannel = MethodChannel('AniAura/ime');

  late final FocusNode _navFocus;
  late final bool _ownsNav;
  late final FocusNode _editFocus;

  bool get _singleLine => (widget.maxLines ?? 1) == 1;
  bool get _chromeFocused => _navFocus.hasFocus || _editFocus.hasFocus;
  bool get _editing => _editFocus.hasFocus;

  @override
  void initState() {
    super.initState();
    final external = widget.focusNode;
    if (external != null) {
      _ownsNav = false;
      _navFocus = external;
      _navFocus.onKeyEvent = _onNavKey;
    } else {
      _ownsNav = true;
      _navFocus = FocusNode(
        debugLabel: 'tv-text-nav',
        onKeyEvent: _onNavKey,
      );
    }
    _editFocus = FocusNode(
      debugLabel: 'tv-text-edit',
      // D-pad traversal hits [_navFocus] only; OK moves focus here to open IME.
      skipTraversal: true,
      onKeyEvent: _onEditKey,
    );
    _navFocus.addListener(_onAnyFocus);
    _editFocus.addListener(_onAnyFocus);
  }

  @override
  void dispose() {
    _navFocus.removeListener(_onAnyFocus);
    _editFocus.removeListener(_onAnyFocus);
    if (_ownsNav) {
      _navFocus.dispose();
    } else {
      _navFocus.onKeyEvent = null;
    }
    _editFocus.dispose();
    super.dispose();
  }

  void _onAnyFocus() {
    if (!mounted) return;
    setState(() {}); // refresh focused chrome + cursor
    if (_chromeFocused) {
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
      );
    }
  }

  KeyEventResult _onNavKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (okKeys.contains(key)) {
      if (widget.enabled) _openIme();
      return KeyEventResult.handled;
    }

    final direction = _directionFor(key);
    if (direction == null) return KeyEventResult.ignored;
    if (node.focusInDirection(direction)) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  KeyEventResult _onEditKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (okKeys.contains(key)) {
      // IME dismissed but field kept focus — ask again.
      if (widget.enabled) _requestIme();
      return KeyEventResult.handled;
    }

    final direction = _directionFor(key);
    if (direction == null) return KeyEventResult.ignored;

    // Single-line: Up/Down leave the field (and close the IME). Left/Right
    // stay with the caret / leanback keyboard. Multi-line: leave all arrows
    // to the IME / caret while editing.
    final leave =
        _singleLine &&
        (direction == TraversalDirection.up ||
            direction == TraversalDirection.down);
    if (!leave) return KeyEventResult.ignored;

    _navFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navFocus.focusInDirection(direction);
    });
    return KeyEventResult.handled;
  }

  TraversalDirection? _directionFor(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowDown) return TraversalDirection.down;
    if (key == LogicalKeyboardKey.arrowUp) return TraversalDirection.up;
    if (key == LogicalKeyboardKey.arrowLeft) return TraversalDirection.left;
    if (key == LogicalKeyboardKey.arrowRight) return TraversalDirection.right;
    return null;
  }

  void _openIme() {
    // Focus-gain on an already-editable field is the path that actually
    // raises leanback. Do not toggle readOnly — that races TextInput.show
    // into PHASE_CLIENT_REPORT_REQUESTED_VISIBLE_TYPES cancellations.
    _editFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _requestIme();
    });
  }

  void _requestIme() {
    SystemChannels.textInput.invokeMethod('TextInput.show');
    _imeChannel.invokeMethod<void>('show').catchError((_) {});
  }

  /// [InputDecoration.focusedBorder] only applies when the *edit* node is
  /// focused; mirror it onto the enabled border while the nav chrome is
  /// focused so D-pad landing still looks selected.
  InputDecoration _decoration() {
    final base = widget.decoration ?? const InputDecoration();
    if (!_navFocus.hasFocus || _editFocus.hasFocus) return base;
    final focused = base.focusedBorder;
    if (focused == null) return base;
    return base.copyWith(enabledBorder: focused, border: focused);
  }

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        // Fire TV often activates via Semantics when it falsely reports a
        // screen reader; keep an explicit tap action on the chrome.
        onTap: widget.enabled ? _openIme : null,
        child: Focus(
          focusNode: _navFocus,
          autofocus: widget.autofocus,
          child: TextField(
            controller: widget.controller,
            focusNode: _editFocus,
            // Never autofocus the edit node — that would raise the IME on
            // tab entry. Nav focus handles landing.
            autofocus: false,
            enabled: widget.enabled,
            readOnly: false,
            showCursor: _editing,
            obscureText: widget.obscureText,
            obscuringCharacter: widget.obscuringCharacter,
            keyboardType: widget.keyboardType,
            textInputAction: widget.textInputAction,
            textCapitalization: widget.textCapitalization,
            autocorrect: widget.autocorrect,
            enableSuggestions: widget.enableSuggestions,
            inputFormatters: widget.inputFormatters,
            maxLines: widget.obscureText ? 1 : widget.maxLines,
            minLines: widget.minLines,
            maxLength: widget.maxLength,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            onTap: widget.enabled ? _openIme : null,
            style:
                widget.style ??
                AppText.body.copyWith(color: AppColors.textPrimary),
            cursorColor: widget.cursorColor ?? AppColors.accent,
            decoration: _decoration(),
          ),
        ),
      ),
    );
  }
}
