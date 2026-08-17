import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'tv_keys.dart';

/// A [TextField] that stays D-pad navigable on Android TV.
///
/// Autofocusing a normal [TextField] raises the leanback IME, which swallows
/// D-pad events so the remote cannot move to the next control. [EditableText]
/// also eats arrow keys for cursor movement even when the IME is closed, and
/// Select/OK does not re-show a dismissed keyboard.
///
/// This widget:
///  * lands focus without opening the IME (`readOnly` until OK)
///  * routes D-pad arrows to [FocusNode.focusInDirection] while not editing
///  * shows the keyboard on OK/Select
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

  /// Optional external focus node. [TvTextField] still owns D-pad / OK handling
  /// on this node; pass one only when a parent needs to [FocusNode.requestFocus]
  /// or listen for focus changes.
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
  late final FocusNode _focus;
  late final bool _ownsFocus;
  bool _editing = false;

  bool get _singleLine => (widget.maxLines ?? 1) == 1;

  @override
  void initState() {
    super.initState();
    final external = widget.focusNode;
    if (external != null) {
      _ownsFocus = false;
      _focus = external;
      _focus.onKeyEvent = _onKey;
    } else {
      _ownsFocus = true;
      _focus = FocusNode(onKeyEvent: _onKey);
    }
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    if (_ownsFocus) {
      _focus.dispose();
    } else {
      _focus.onKeyEvent = null;
    }
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    if (_focus.hasFocus) {
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
      );
    } else if (_editing) {
      setState(() => _editing = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (okKeys.contains(key)) {
      if (widget.enabled) _showIme();
      return KeyEventResult.handled;
    }

    final direction = _directionFor(key);
    if (direction == null) return KeyEventResult.ignored;

    // While editing a multi-line field, leave arrows to the caret / IME.
    final stealArrows =
        !_editing ||
        (_singleLine &&
            (direction == TraversalDirection.up ||
                direction == TraversalDirection.down));
    if (!stealArrows) return KeyEventResult.ignored;

    if (node.focusInDirection(direction)) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  TraversalDirection? _directionFor(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowDown) return TraversalDirection.down;
    if (key == LogicalKeyboardKey.arrowUp) return TraversalDirection.up;
    if (key == LogicalKeyboardKey.arrowLeft) return TraversalDirection.left;
    if (key == LogicalKeyboardKey.arrowRight) return TraversalDirection.right;
    return null;
  }

  void _showIme() {
    if (!_editing) setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_focus.hasFocus) _focus.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      readOnly: !_editing,
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
      onTap: widget.enabled ? _showIme : null,
      style:
          widget.style ?? AppText.body.copyWith(color: AppColors.textPrimary),
      cursorColor: widget.cursorColor ?? AppColors.accent,
      decoration: widget.decoration,
    );
  }
}
