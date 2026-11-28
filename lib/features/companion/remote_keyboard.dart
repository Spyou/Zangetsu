import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/global_messenger.dart';
import 'remote_session.dart';

/// Field id of a protocol v1 keyboard snapshot, or null.
int? keyboardField(Map<String, dynamic>? snapshot) =>
    (snapshot?['field'] as num?)?.toInt();

/// Streams one phone text box to the selected TV text box.
///
/// The whole text is sent (never deltas), at most one request is in flight and
/// the latest text wins. TV text is only adopted when it cannot fight typing.
class RemoteKeyboardController extends ChangeNotifier {
  /// Listens to [session]'s keyboard snapshots (the shared session by default)
  /// and adopts the current one straight away. Tests pass a short [debounce].
  RemoteKeyboardController({
    RemoteSession? session,
    this.debounce = const Duration(milliseconds: 60),
  }) : session = session ?? RemoteSession.instance {
    this.session.keyboard.addListener(_onSnapshot);
    adopt(this.session.keyboard.value);
  }

  /// The remote connection that carries keyboard snapshots and commands.
  final RemoteSession session;

  /// How long typing pauses before the text is sent to the TV.
  final Duration debounce;

  /// After this long without phone edits, changed TV text replaces local text.
  static const _quiet = Duration(milliseconds: 1200);

  /// Mirrors [local]; programmatic changes do not fire TextField.onChanged.
  final editor = TextEditingController();

  /// Latest TV keyboard snapshot, or null while no TV text box is selected.
  Map<String, dynamic>? snapshot;

  /// Id of the TV text box this controller is bound to.
  int? field;

  /// Text currently in the phone box.
  String local = '';

  /// Last text the TV confirmed (or reported), used for the sync dot.
  String acked = '';

  /// True while a keyboardInput request is waiting for the TV's reply.
  bool inFlight = false;

  /// Local text changed since the last send.
  bool _dirty = false;

  /// When the user last typed on the phone; guards TV text adoption.
  DateTime lastEditAt = DateTime(0);

  /// Debounce timer for the next send.
  Timer? _timer;
  bool _disposed = false;

  /// The TV box is a password field: text is hidden and never echoed back.
  bool get secure => snapshot?['secure'] == true;

  /// True when the TV has everything the phone typed.
  bool get synced => !_dirty && !inFlight && acked == local;

  /// Text the TV currently shows in its box.
  String get tvText => snapshot?['text'] as String? ?? '';

  /// The TV box's placeholder text.
  String get hint => snapshot?['hint'] as String? ?? '';

  /// TV's IME action: search, go, next, send, newline or done.
  String get action => snapshot?['action'] as String? ?? 'done';

  /// TV's input type: text, number, email or url.
  String get type => snapshot?['type'] as String? ?? 'text';

  /// Whether the TV box accepts several lines.
  bool get multiline => snapshot?['multiline'] == true;

  /// The TV box's character limit, if it has one.
  int? get maxLength => (snapshot?['maxLength'] as num?)?.toInt();

  /// Session listener: adopts each new snapshot.
  void _onSnapshot() => adopt(session.keyboard.value);

  /// Applies a TV snapshot; a new field id retargets the sheet in place.
  void adopt(Map<String, dynamic>? next) {
    if (_disposed) return;
    snapshot = next;
    if (next != null) {
      final id = keyboardField(next);
      final text = next['text'] as String? ?? '';
      if (id != field) {
        field = id;
        _timer?.cancel();
        _dirty = false;
        acked = text;
        _setLocal(text);
      } else if (!secure &&
          !inFlight &&
          !_dirty &&
          DateTime.now().difference(lastEditAt) > _quiet &&
          text != local) {
        acked = text;
        _setLocal(text);
      } else if (!secure && !inFlight && !_dirty && text == local) {
        acked = local;
      }
    }
    notifyListeners();
  }

  /// Sets [local] and the editor together, with the cursor at the end.
  void _setLocal(String text) {
    local = text;
    editor.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Phone typing: coalesced into one keyboardInput carrying the full text.
  void onLocalChanged(String text) {
    local = text;
    lastEditAt = DateTime.now();
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(debounce, _flush);
    notifyListeners();
  }

  /// Replaces the text (Paste/Clear) and streams it like typing.
  void replace(String text) {
    final limit = maxLength ?? 1000;
    if (text.length > limit) text = text.substring(0, limit);
    _setLocal(text);
    onLocalChanged(text);
  }

  /// Sends the full local text as keyboardInput, one request at a time.
  Future<void> _flush() async {
    if (_disposed || inFlight || !_dirty || field == null) return;
    _dirty = false;
    inFlight = true;
    final sent = local;
    notifyListeners();
    final reply = await session.keyboardCommand('keyboardInput', {
      'field': field,
      'text': sent,
    });
    inFlight = false;
    if (_disposed) return;
    if (reply['ok'] == true) acked = sent;
    notifyListeners();
    // The latest text wins: anything typed during the round trip goes next.
    if (_dirty) unawaited(_flush());
  }

  /// Sends text the TV has not seen yet right away (the sheet is closing);
  /// queued before the keyboardDismiss that follows it.
  void flushNow() {
    _timer?.cancel();
    final id = field;
    if (!_dirty || id == null) return;
    _dirty = false;
    unawaited(
      session.keyboardCommand('keyboardInput', {'field': id, 'text': local}),
    );
  }

  /// Sends the final text plus the TV's submit; ordered after pending input.
  Future<void> submit() async {
    _timer?.cancel();
    _dirty = false;
    final id = field;
    if (id == null) return;
    await session.keyboardCommand('keyboardSubmit', {
      'field': id,
      'text': local,
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    session.keyboard.removeListener(_onSnapshot);
    editor.dispose();
    super.dispose();
  }
}

/// Why the sheet closed: the user dismissed it, submitted, or the TV left the
/// text box (then nothing is sent back).
enum _Close { user, submit, tv }

/// How the open sheet ended; read as soon as its route pops, before disposal.
class _Outcome {
  /// The TV field the sheet was bound to when it closed.
  int? field;

  /// Sends any unsent text; set by the sheet state.
  void Function()? flush;
  _Close reason = _Close.user;
}

/// Phone keyboard sheet for the selected TV text box.
class RemoteKeyboardSheet extends StatefulWidget {
  /// Use [show] rather than building this directly.
  const RemoteKeyboardSheet({super.key, this.manual = false});

  /// Opened by the user's keyboard button; asks the TV to open its keyboard
  /// when no text box is selected yet.
  final bool manual;

  /// The last field the phone submitted or dismissed; it is not auto-opened again.
  static int? lastDismissedField;

  /// True while a sheet is on screen, so only one opens at a time.
  static bool isOpen = false;

  /// Outcome of the sheet currently open, filled in by its state.
  static _Outcome? _outcome;

  /// Opens the sheet once; does nothing for TVs without keyboard support.
  static Future<void> show(BuildContext context, {bool manual = false}) async {
    if (isOpen || !RemoteSession.instance.keyboardSupported) return;
    isOpen = true;
    final outcome = _outcome = _Outcome();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (_) => RemoteKeyboardSheet(manual: manual),
      );
    } finally {
      // Swipe-down, back and the X button all count as a user dismiss.
      final field = outcome.field;
      if (field != null && outcome.reason != _Close.tv) {
        lastDismissedField = field;
        if (outcome.reason == _Close.user) {
          // Text typed in the debounce or during a round trip still lands.
          outcome.flush?.call();
          unawaited(
            RemoteSession.instance.keyboardCommand('keyboardDismiss', {
              'field': field,
            }),
          );
        }
      }
      if (identical(_outcome, outcome)) _outcome = null;
      isOpen = false;
    }
  }

  @override
  State<RemoteKeyboardSheet> createState() => _RemoteKeyboardSheetState();
}

/// Owns the controller, refocuses on a new TV field and closes when the TV
/// leaves the text box.
class _RemoteKeyboardSheetState extends State<RemoteKeyboardSheet> {
  final _controller = RemoteKeyboardController();
  final _focus = FocusNode();

  /// Set once the sheet starts popping, so it closes only once.
  bool _closing = false;

  /// Grace timer before closing after the TV snapshot disappears.
  Timer? _gone;

  /// Field id the text box was last focused for.
  int? _attached;

  @override
  void initState() {
    super.initState();
    _attached = _controller.field;
    RemoteKeyboardSheet._outcome
      ?..field = _controller.field
      ..flush = _controller.flushNow;
    _controller.addListener(_changed);
    if (widget.manual && _controller.field == null) {
      unawaited(_controller.session.keyboardCommand('keyboardOpen'));
    }
  }

  /// Controller listener: tracks the field, TV departure and refocus.
  void _changed() {
    if (!mounted) return;
    final c = _controller;
    if (!_closing) RemoteKeyboardSheet._outcome?.field = c.field;
    // The TV left the text box: close quietly once it stays gone.
    if (c.snapshot == null && c.field != null) {
      _gone ??= Timer(const Duration(milliseconds: 600), () {
        if (_controller.snapshot == null) _close(_Close.tv);
      });
    } else {
      _gone?.cancel();
      _gone = null;
    }
    if (c.snapshot != null && c.field != _attached) {
      _attached = c.field;
      _focus.requestFocus();
    }
    setState(() {});
  }

  /// Records [reason] for [RemoteKeyboardSheet.show] and pops the sheet.
  void _close(_Close reason) {
    if (_closing || !mounted) return;
    _closing = true;
    RemoteKeyboardSheet._outcome?.reason = reason;
    Navigator.of(context).pop();
  }

  /// Action button or keyboard enter: submits on the TV and closes.
  Future<void> _submit() async {
    if (_controller.field == null || _closing) return;
    unawaited(_controller.submit());
    unawaited(HapticFeedback.lightImpact());
    _close(_Close.submit);
  }

  @override
  void dispose() {
    _gone?.cancel();
    _controller.removeListener(_changed);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Borderless rounded outline; fully round for one line, softer for several.
  static OutlineInputBorder _fieldBorder(bool multiline) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(multiline ? 20 : 28),
    borderSide: BorderSide.none,
  );

  /// Maps the TV's input type to the phone keyboard layout.
  static TextInputType _inputType(String type, bool multiline) =>
      switch (type) {
        'number' => TextInputType.number,
        'email' => TextInputType.emailAddress,
        'url' => TextInputType.url,
        _ => multiline ? TextInputType.multiline : TextInputType.text,
      };

  /// Maps the TV's IME action to the phone keyboard's enter key.
  static TextInputAction _inputAction(String action, bool multiline) =>
      switch (action) {
        'search' => TextInputAction.search,
        'go' => TextInputAction.go,
        'next' => TextInputAction.next,
        'send' => TextInputAction.send,
        'newline' when multiline => TextInputAction.newline,
        _ => TextInputAction.done,
      };

  /// Label for the sheet's action button, matching the TV's action.
  static String _actionLabel(String action) => switch (action) {
    'search' => 'Search',
    'go' => 'Go',
    'next' => 'Next',
    'send' => 'Send',
    _ => 'Done',
  };

  /// Header, the text box, a sync line and the TV's action button.
  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final attached = c.snapshot != null;
    final hint = attached ? c.hint : 'Select a text box on the TV';
    // Keyboard up: sit on it. Keyboard down: clear the iPhone home indicator
    // (Android keeps its previous layout).
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final safe = Platform.isIOS
        ? MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    return Padding(
      padding: EdgeInsets.only(bottom: inset > 0 ? inset : safe),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.tv_rounded, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Typing on ${c.session.name}',
                        style: AppText.title.copyWith(fontSize: 18),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (hint.isNotEmpty)
                        Text(
                          hint,
                          style: AppText.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close keyboard',
                  onPressed: () => _close(_Close.user),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('remoteKeyboardField'),
              controller: c.editor,
              focusNode: _focus,
              autofocus: true,
              enabled: attached,
              obscureText: c.secure,
              autocorrect: !c.secure,
              enableSuggestions: !c.secure,
              keyboardType: _inputType(c.type, c.multiline),
              textInputAction: _inputAction(c.action, c.multiline),
              maxLength: c.maxLength,
              minLines: 1,
              maxLines: c.multiline && !c.secure ? 4 : 1,
              onChanged: c.onLocalChanged,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: attached
                    ? (c.hint.isEmpty ? 'Type here' : c.hint)
                    : null,
                counterText: '',
                filled: true,
                fillColor: AppColors.surface2,
                // Pill-shaped like the Search button beside it; a multi-line
                // box keeps softer corners so its extra lines don't look odd.
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                border: _fieldBorder(c.multiline && !c.secure),
                enabledBorder: _fieldBorder(c.multiline && !c.secure),
                disabledBorder: _fieldBorder(c.multiline && !c.secure),
                focusedBorder: _fieldBorder(c.multiline && !c.secure),
              ),
            ),
            if (attached) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    key: const ValueKey('remoteKeyboardSync'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.synced
                          ? Colors.green.shade400
                          : Colors.amber.shade600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.secure
                          ? (c.synced ? 'On TV' : 'Sending to TV…')
                          : 'On TV: ${c.tvText}',
                      style: AppText.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            // Minimal: the phone keyboard's own paste and delete keys cover
            // Paste/Clear, so only the TV's action button stays.
            Row(
              children: [
                const Spacer(),
                FilledButton(
                  onPressed: attached ? _submit : null,
                  child: Text(_actionLabel(c.action)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Auto-opens the keyboard sheet while the remote page is visible.
///
/// Wraps the remote page; opens the sheet when the TV marks a snapshot `auto`
/// and the field is not the one the user just dismissed.
class RemoteKeyboardHost extends StatefulWidget {
  /// Wraps [child]; [autoOpen] is true while the remote page is on screen.
  const RemoteKeyboardHost({
    super.key,
    required this.autoOpen,
    required this.child,
  });

  /// Whether this host may open the sheet right now.
  final bool autoOpen;

  /// The page shown under the sheet.
  final Widget child;

  /// Hosts currently able to auto-open; the global prompter stays quiet while > 0.
  static int visibleHosts = 0;

  @override
  State<RemoteKeyboardHost> createState() => _RemoteKeyboardHostState();
}

/// Keeps [RemoteKeyboardHost.visibleHosts] in step and watches snapshots.
class _RemoteKeyboardHostState extends State<RemoteKeyboardHost> {
  final _session = RemoteSession.instance;

  /// Whether this host is currently counted in visibleHosts.
  bool _counted = false;

  @override
  void initState() {
    super.initState();
    _count(widget.autoOpen);
    _session.keyboard.addListener(_check);
    _check();
  }

  @override
  void didUpdateWidget(covariant RemoteKeyboardHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _count(widget.autoOpen);
    if (widget.autoOpen && !oldWidget.autoOpen) _check();
  }

  /// Adds or removes this host from the visible count, once per change.
  void _count(bool visible) {
    if (visible == _counted) return;
    _counted = visible;
    RemoteKeyboardHost.visibleHosts += visible ? 1 : -1;
  }

  /// True when the TV asks for text and no sheet is open for that field.
  bool get _wantsSheet {
    final snapshot = _session.keyboard.value;
    return widget.autoOpen &&
        _session.keyboardSupported &&
        snapshot != null &&
        snapshot['auto'] == true &&
        keyboardField(snapshot) != RemoteKeyboardSheet.lastDismissedField &&
        !RemoteKeyboardSheet.isOpen;
  }

  /// Opens the sheet after the current frame if it is still wanted then.
  void _check() {
    if (!_wantsSheet) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _wantsSheet) unawaited(RemoteKeyboardSheet.show(context));
    });
  }

  @override
  void dispose() {
    _count(false);
    _session.keyboard.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Shows a one-time "Type" SnackBar when the TV waits for text while the
/// remote page is not on screen.
class RemoteKeyboardPrompter {
  static bool _started = false;

  /// Field already prompted for, so each TV text box prompts once.
  static int? _prompted;

  /// Starts listening to keyboard snapshots; call once at app start.
  static void start() {
    if (_started) return;
    _started = true;
    RemoteSession.instance.keyboard.addListener(_check);
  }

  /// Shows the SnackBar when the app is in front and no host or sheet is up.
  static void _check() {
    final session = RemoteSession.instance;
    final snapshot = session.keyboard.value;
    final field = keyboardField(snapshot);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (snapshot == null ||
        snapshot['auto'] != true ||
        !session.keyboardSupported ||
        RemoteKeyboardHost.visibleHosts > 0 ||
        RemoteKeyboardSheet.isOpen ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
        field == null ||
        field == _prompted ||
        field == RemoteKeyboardSheet.lastDismissedField) {
      return;
    }
    final messenger = rootMessengerKey.currentState;
    if (messenger == null) return;
    _prompted = field;
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Your TV is waiting for text'),
        action: SnackBarAction(
          label: 'Type',
          onPressed: () {
            final navigator = rootNavigatorKey.currentState;
            final c =
                navigator?.overlay?.context ?? rootNavigatorKey.currentContext;
            if (c != null) unawaited(RemoteKeyboardSheet.show(c));
          },
        ),
      ),
    );
  }
}
