import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A TV text box the phone keyboard can type into.
///
/// [TvTextField] and the New search keyboard register one explicitly; any
/// other focused [EditableText] is picked up generically by the bridge.
abstract class TvKeyboardTarget {
  /// The box (or its D-pad chrome) holds focus.
  bool get focused;

  /// The TV is actively editing it (IME up / keyboard grid focused).
  bool get editing;

  /// Current text; the bridge never sends it to the phone when [secure].
  String get text;

  /// Placeholder or label shown on the phone keyboard; empty when none.
  String get hint;

  /// Password-style box: the phone shows dots and gets no existing text.
  bool get secure;

  /// IME action used to pick the phone's return key; null means default.
  TextInputAction? get inputAction;

  /// Keyboard type mapped to the phone's text/number/email/url layouts.
  TextInputType? get inputType;

  /// Whether the box accepts several lines (ignored when [secure]).
  bool get multiline;

  /// Character limit enforced on phone input; null or 0 means none.
  int? get maxLength;

  /// Replaces the whole text, running the box's own change handling.
  void setText(String text);

  /// Runs the box's submit/search action.
  void submit();

  /// Hides the TV IME for this box; focus stays on it.
  void dismiss();
}

/// TV-side registry of the active text box, serving phone keyboard protocol v1.
///
/// It only observes focus; it never requests focus itself.
class TvKeyboardBridge {
  /// Creates a separate bridge; the app uses [instance], tests may make more.
  TvKeyboardBridge();

  /// App-wide bridge, started by the TV build and used by the remote server.
  static final TvKeyboardBridge instance = TvKeyboardBridge();

  /// Remote request actions routed to [handle]; anything else is not ours.
  static const Set<String> actions = {
    'keyboardOpen',
    'keyboardInput',
    'keyboardSubmit',
    'keyboardDismiss',
  };

  /// Native channel; Android receives 'receiverKeyboard' snapshot JSON here.
  static const _channel = MethodChannel('zangetsu/companion');

  /// Hard cap on text sent either way, in characters (grapheme clusters).
  static const _maxText = 1000;

  /// Cap on the hint sent to the phone.
  static const _maxHint = 80;

  /// Debounce before pushing a snapshot, so bursts of changes send once.
  static const _pushDelay = Duration(milliseconds: 40);

  /// How long [phoneTyping] stays true after the last phone keystroke.
  static const _typingHold = Duration(seconds: 3);

  /// Android TV receives snapshots through the native receiver; Apple reads
  /// [snapshot] directly. Overridable so tests can exercise the push.
  @visibleForTesting
  bool Function() isAndroid = _platformIsAndroid;

  /// Default for [isAndroid]: true only on a real Android device.
  static bool _platformIsAndroid() => !kIsWeb && Platform.isAndroid;

  /// Explicitly registered boxes, checked in order before the generic one.
  final _targets = <TvKeyboardTarget>[];
  final _phoneTyping = ValueNotifier<bool>(false);
  bool _started = false;

  /// The box currently offered to the phone, or null.
  TvKeyboardTarget? _target;

  /// What makes a box "the same box" (target, or EditableTextState).
  Object? _identity;
  bool _wasEditing = false;

  /// Field id sent to the phone; changes per box/edit so stale input is
  /// rejected. Random start so a restarted TV never reuses an old id.
  int _field = Random().nextInt(1 << 30);

  /// Field the user submitted or dismissed, so it no longer auto-opens.
  int? _dismissedField;

  /// Controller of the generic box, listened to for text changes.
  TextEditingController? _watched;
  Timer? _typingTimer;
  Timer? _pushTimer;

  /// Last JSON pushed to Android, used to skip duplicate pushes.
  String? _lastPush;
  bool _pushedOnce = false;

  /// True for a few seconds after the phone opened or typed into a box.
  ValueListenable<bool> get phoneTyping => _phoneTyping;

  /// Starts observing focus. Safe to call more than once.
  void start() {
    if (_started) return;
    _started = true;
    FocusManager.instance.addListener(_reevaluate);
    _reevaluate();
  }

  /// Adds a custom box (e.g. from its initState); duplicates are ignored.
  void register(TvKeyboardTarget t) {
    if (!_targets.contains(t)) _targets.add(t);
    if (_started) _reevaluate();
  }

  /// Removes a box registered with [register], typically from dispose.
  void unregister(TvKeyboardTarget t) {
    _targets.remove(t);
    if (_started) _reevaluate();
  }

  /// Targets call this when focus, editing state, or text changed.
  void changed() {
    if (_started) _reevaluate();
  }

  /// The active box for the phone, or null when none is selected.
  ///
  /// Keys: field, text, hint, secure, action, type, multiline, maxLength and
  /// auto (true when the phone should open its keyboard by itself).
  Map<String, dynamic>? snapshot() {
    _reevaluate();
    return _current();
  }

  /// Serves keyboardOpen/Input/Submit/Dismiss. Never throws and never adds
  /// an 'error' key: a missing box or stale field is just ok:false.
  ///
  /// The request carries 'action', 'field' and (for input/submit) the full
  /// 'text'; the reply is `{ok, keyboard}` with the fresh [snapshot].
  Future<Map<String, dynamic>> handle(Map<String, dynamic> request) async {
    _reevaluate();
    final target = _target;
    final rawField = request['field'];
    final fieldMatches =
        target != null && rawField is num && rawField.toInt() == _field;
    final rawText = request['text'];
    final text = target == null
        ? ''
        : _truncate(rawText is String ? rawText : '', target.maxLength);
    var ok = false;
    try {
      switch (request['action']) {
        case 'keyboardOpen':
          ok = target != null;
          if (_dismissedField == _field) _dismissedField = null;
          if (ok) _markTyping();
        case 'keyboardInput':
          if (!fieldMatches) break;
          if (target.text != text) target.setText(text);
          _markTyping();
          ok = true;
        case 'keyboardSubmit':
          if (!fieldMatches) break;
          if (target.text != text) target.setText(text);
          target.submit();
          _dismissedField = _field;
          ok = true;
        case 'keyboardDismiss':
          if (!fieldMatches) break;
          target.dismiss();
          _dismissedField = _field;
          ok = true;
      }
    } catch (_) {
      // A box that vanished mid-action reports as not handled.
      ok = false;
    }
    _reevaluate();
    return {'ok': ok, 'keyboard': _current()};
  }

  /// Clears runtime state between tests; registered targets are kept.
  @visibleForTesting
  void debugReset({bool Function()? isAndroid}) {
    if (_started) FocusManager.instance.removeListener(_reevaluate);
    _started = false;
    _unwatch();
    _target = null;
    _identity = null;
    _wasEditing = false;
    _field = Random().nextInt(1 << 30);
    _dismissedField = null;
    _typingTimer?.cancel();
    _pushTimer?.cancel();
    _pushTimer = null;
    _phoneTyping.value = false;
    _lastPush = null;
    _pushedOnce = false;
    this.isAndroid = isAndroid ?? _platformIsAndroid;
  }

  /// Sets [phoneTyping] and restarts its hold timer.
  void _markTyping() {
    _phoneTyping.value = true;
    _typingTimer?.cancel();
    _typingTimer = Timer(_typingHold, () => _phoneTyping.value = false);
  }

  /// Picks the active box and bumps the field id on identity or edit start.
  void _reevaluate() {
    TvKeyboardTarget? target;
    for (final t in _targets) {
      if (t.focused) {
        target = t;
        break;
      }
    }
    target ??= _genericTarget();
    final identity = target is _EditableTarget ? target.state : target;
    final editing = target?.editing ?? false;
    if (!identical(identity, _identity)) {
      if (identity != null) _bump();
      _identity = identity;
      _unwatch();
      if (target is _EditableTarget) {
        _watched = target.state.widget.controller..addListener(changed);
      }
    } else if (identity != null && editing && !_wasEditing) {
      _bump();
    }
    _target = target;
    _wasEditing = editing;
    _schedulePush();
  }

  /// Moves to a new field id (30-bit wrap) and clears the dismissed mark.
  void _bump() {
    _field = (_field + 1) & 0x3fffffff;
    _dismissedField = null;
  }

  /// Stops listening to the generic box's controller (it may be disposed).
  void _unwatch() {
    try {
      _watched?.removeListener(changed);
    } catch (_) {}
    _watched = null;
  }

  /// Any plain focused, writable [EditableText] (login, settings, ...).
  TvKeyboardTarget? _genericTarget() {
    final node = FocusManager.instance.primaryFocus;
    final context = node?.context;
    if (node == null || context == null) return null;
    try {
      final state = context.findAncestorStateOfType<EditableTextState>();
      if (state == null || !state.mounted) return null;
      if (!identical(state.widget.focusNode, node)) return null;
      if (state.widget.readOnly) return null;
      return _EditableTarget(state);
    } catch (_) {
      return null;
    }
  }

  /// Builds the [snapshot] map from the cached target without re-evaluating.
  Map<String, dynamic>? _current() {
    final t = _target;
    if (t == null) return null;
    final secure = t.secure;
    final multiline = t.multiline && !secure;
    final maxLength = (t.maxLength ?? 0) > 0 ? t.maxLength : null;
    return {
      'field': _field,
      'text': secure ? '' : _truncate(t.text, maxLength),
      'hint': _clip(t.hint, _maxHint),
      'secure': secure,
      'action': _action(t.inputAction, multiline),
      'type': _type(t.inputType),
      'multiline': multiline,
      'maxLength': maxLength,
      'auto': t.editing && _field != _dismissedField,
    };
  }

  /// Clips to the box's maxLength, never beyond the global text cap.
  static String _truncate(String text, int? maxLength) {
    final limit = maxLength != null && maxLength > 0 && maxLength < _maxText
        ? maxLength
        : _maxText;
    return _clip(text, limit);
  }

  /// Cuts to [limit] user-visible characters without splitting emoji.
  static String _clip(String text, int limit) {
    if (text.length <= limit) return text;
    final chars = text.characters;
    return chars.length <= limit ? text : chars.take(limit).toString();
  }

  /// Wire name of the phone's return key; unsupported actions become 'done'.
  static String _action(TextInputAction? action, bool multiline) {
    switch (action ??
        (multiline ? TextInputAction.newline : TextInputAction.done)) {
      case TextInputAction.search:
        return 'search';
      case TextInputAction.go:
        return 'go';
      case TextInputAction.next:
        return 'next';
      case TextInputAction.send:
        return 'send';
      case TextInputAction.newline:
        return 'newline';
      default:
        return 'done';
    }
  }

  /// Wire name of the phone keyboard layout: number, email, url or text.
  static String _type(TextInputType? type) {
    final index = type?.index;
    if (index == TextInputType.number.index ||
        index == TextInputType.phone.index) {
      return 'number';
    }
    if (index == TextInputType.emailAddress.index) return 'email';
    if (index == TextInputType.url.index) return 'url';
    return 'text';
  }

  /// Android only: pushes the deduped snapshot JSON to the native receiver.
  void _schedulePush() {
    // Phone builds never start the bridge, so they never push.
    if (!_started || !isAndroid()) return;
    final json = _encode();
    if (_pushTimer == null && _pushedOnce && json == _lastPush) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(_pushDelay, () {
      _pushTimer = null;
      final latest = _encode();
      if (_pushedOnce && latest == _lastPush) return;
      _pushedOnce = true;
      _lastPush = latest;
      unawaited(
        _channel
            .invokeMethod<void>('receiverKeyboard', latest)
            .catchError((_) {}),
      );
    });
  }

  /// Current snapshot as JSON; null when no box is active.
  String? _encode() {
    final snapshot = _current();
    return snapshot == null ? null : jsonEncode(snapshot);
  }
}

/// Generic adapter over a focused [EditableText] that nobody registered.
class _EditableTarget implements TvKeyboardTarget {
  _EditableTarget(this.state);

  /// The focused field's state; also the identity the bridge compares.
  final EditableTextState state;

  EditableText get _widget => state.widget;

  /// Enclosing [TextField], if any, for its hint and maxLength.
  TextField? get _textField {
    if (!state.mounted) return null;
    try {
      return state.context.findAncestorWidgetOfExactType<TextField>();
    } catch (_) {
      return null; // Element is being torn down.
    }
  }

  /// Only created for the primary focus, so always focused and editing.
  @override
  bool get focused => true;

  @override
  bool get editing => true;

  @override
  String get text => _widget.controller.text;

  @override
  String get hint {
    final decoration = _textField?.decoration;
    return decoration?.hintText ?? decoration?.labelText ?? '';
  }

  @override
  bool get secure => _widget.obscureText;

  @override
  TextInputAction? get inputAction => _widget.textInputAction;

  @override
  TextInputType? get inputType => _widget.keyboardType;

  @override
  bool get multiline => _widget.maxLines != 1;

  @override
  int? get maxLength => _textField?.maxLength;

  @override
  void setText(String text) {
    // Same path as IME input: formatters, maxLength and onChanged all run.
    state.userUpdateTextEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  @override
  void submit() => state.performAction(
    _widget.textInputAction ??
        (multiline ? TextInputAction.newline : TextInputAction.done),
  );

  @override
  void dismiss() {
    unawaited(
      SystemChannels.textInput
          .invokeMethod<void>('TextInput.hide')
          .catchError((_) {}),
    );
  }
}
