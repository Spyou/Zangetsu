import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/cache/app_image_cache.dart';
import '../../l10n/l10n.dart';

Future<String?> showPhoneVoiceSearchSheet(
  BuildContext context, {
  String? gifUrl,
}) async {
  ModalRoute<dynamic>? sheetRoute;
  final result = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    requestFocus: false,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    builder: (context) {
      sheetRoute = ModalRoute.of(context);
      return _PhoneVoiceSearchSheet(gifUrl: gifUrl);
    },
  );
  await sheetRoute?.completed;
  return result;
}

class _PhoneVoiceSearchSheet extends StatefulWidget {
  const _PhoneVoiceSearchSheet({this.gifUrl});
  final String? gifUrl;

  @override
  State<_PhoneVoiceSearchSheet> createState() => _PhoneVoiceSearchSheetState();
}

class _PhoneVoiceSearchSheetState extends State<_PhoneVoiceSearchSheet>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('zangetsu/phone_voice_search');
  static int _nextSession = 0;
  static _PhoneVoiceSearchSheetState? _handlerOwner;
  int _session = 0;
  bool _active = false;
  bool _requestingPermission = false;
  bool _permanentlyDenied = false;
  bool _closing = false;
  String _state = 'starting';
  String? _error;
  String _transcript = '';
  double _level = 0;
  Timer? _deadline;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _handlerOwner = this;
    _channel.setMethodCallHandler(_onState);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_listen());
    });
  }

  Future<void> _onState(MethodCall call) async {
    if (!mounted || !_active || call.method != 'state') return;
    final args = call.arguments;
    if (args is! Map || args['sessionId'] != _session) return;
    final state = args['state'];
    if (state == 'partial') {
      final text = args['text'];
      if (text is String &&
          text.trim().isNotEmpty &&
          text.trim() != _transcript) {
        setState(() => _transcript = text.trim());
      }
    } else if (state == 'level') {
      final value = args['level'];
      if (value is! num || !value.isFinite || _state != 'listening') return;
      setState(() => _level = value.toDouble().clamp(0, 1));
    } else if (state == 'listening' || state == 'processing') {
      setState(() {
        _state = state as String;
        _level = 0;
      });
    }
  }

  Future<void> _listen() async {
    if (_active || _requestingPermission || _closing) return;
    final session = _session = ++_nextSession;
    setState(() {
      _state = 'starting';
      _error = null;
      _transcript = '';
      _permanentlyDenied = false;
      _level = 0;
    });
    try {
      _requestingPermission = true;
      final permission = await Permission.microphone.request();
      _requestingPermission = false;
      if (!mounted || _closing || session != _session) return;
      if (!permission.isGranted) {
        setState(() {
          _error = 'voice_permission';
          _permanentlyDenied = permission.isPermanentlyDenied;
        });
        return;
      }
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle == AppLifecycleState.paused ||
          lifecycle == AppLifecycleState.detached ||
          lifecycle == AppLifecycleState.hidden) {
        _dismiss();
        return;
      }
      _active = true;
      _deadline = Timer(const Duration(seconds: 35), () {
        if (!mounted || _closing || _session != session) return;
        _session = ++_nextSession;
        _active = false;
        unawaited(_cancel(session));
        setState(() {
          _level = 0;
          _error = 'voice_failed';
        });
      });
      final text = await _channel.invokeMethod<String>('listen', {
        'sessionId': session,
      });
      if (!mounted || _closing || session != _session) return;
      _deadline?.cancel();
      _active = false;
      _closing = true;
      final query = text?.trim();
      Navigator.of(context).pop(query == null || query.isEmpty ? null : query);
    } catch (error) {
      if (!mounted || _closing || session != _session) return;
      _deadline?.cancel();
      _requestingPermission = false;
      _active = false;
      unawaited(_cancel(session));
      setState(() {
        _level = 0;
        _error = error is PlatformException ? error.code : 'voice_failed';
        _permanentlyDenied = _error == 'voice_speech_permission';
      });
    }
  }

  Future<void> _cancel(int session) async {
    try {
      await _channel
          .invokeMethod<void>('cancel', {'sessionId': session})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Native teardown also cancels on pause/destroy if the channel is gone.
    }
  }

  void _dismiss() {
    if (!mounted || _closing) return;
    _deadline?.cancel();
    _closing = true;
    _active = false;
    unawaited(_cancel(_session));
    Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_requestingPermission &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached ||
            state == AppLifecycleState.hidden)) {
      _dismiss();
    }
  }

  @override
  void dispose() {
    _deadline?.cancel();
    _closing = true;
    _active = false;
    unawaited(_cancel(_session));
    if (identical(_handlerOwner, this)) {
      _channel.setMethodCallHandler(null);
      _handlerOwner = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final processing = _state == 'processing' && _error == null;
    final hearing = _active && _state == 'listening' && _error == null;
    final status = switch (_error) {
      'voice_permission' => context.l10n.voiceSearchPermission,
      'voice_speech_permission' => context.l10n.voiceSearchSpeechPermission,
      'voice_no_match' => context.l10n.voiceSearchNoMatch,
      null =>
        processing
            ? context.l10n.voiceSearchProcessing
            : _state == 'starting'
            ? context.l10n.voiceSearchPreparing
            : context.l10n.voiceSearchListening,
      _ => context.l10n.voiceSearchFailed,
    };
    return PopScope<String>(
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
        _closing = true;
        _active = false;
        _deadline?.cancel();
        unawaited(_cancel(_session));
      },
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.l10n.voiceSearch, style: text.titleLarge),
              const SizedBox(height: 24),
              ExcludeSemantics(
                child: SizedBox.square(
                  dimension: 152,
                  child: Center(
                    child: AnimatedScale(
                      scale: hearing && !reduceMotion ? 1 + _level * .025 : 1,
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 100),
                      child: TickerMode(
                        key: const ValueKey('voice-search-art'),
                        enabled: hearing && !reduceMotion,
                        child: widget.gifUrl == null
                            ? const SizedBox.shrink()
                            : Image(
                                image: AppImageCache.imageProvider(
                                  widget.gifUrl!,
                                ),
                                width: 152,
                                height: 152,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                errorBuilder: (_, _, _) =>
                                    const SizedBox.shrink(),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              ExcludeSemantics(
                child: SizedBox(
                  height: 28,
                  child: processing
                      ? Center(
                          child: SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.primary,
                            ),
                          ),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(7, (i) {
                            final strength = 1 - (i - 3).abs() * .18;
                            return AnimatedContainer(
                              duration: reduceMotion
                                  ? Duration.zero
                                  : const Duration(milliseconds: 100),
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              width: 4,
                              height:
                                  4 +
                                  (reduceMotion ? 0 : _level * 24 * strength),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: colors.primary,
                              ),
                            );
                          }),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  status,
                  style: text.titleMedium,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _transcript.isNotEmpty
                    ? _transcript
                    : _error == null
                    ? context.l10n.speakTheTitle
                    : context.l10n.voiceSearchTypingAvailable,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: _transcript.isNotEmpty
                    ? text.bodyLarge?.copyWith(color: colors.onSurface)
                    : text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              if (_error != null) ...[
                FilledButton.icon(
                  onPressed: _permanentlyDenied ? openAppSettings : _listen,
                  icon: Icon(
                    _permanentlyDenied
                        ? Icons.settings_outlined
                        : Icons.mic_rounded,
                  ),
                  label: Text(
                    _permanentlyDenied
                        ? context.l10n.settingsTitle
                        : context.l10n.tryAgain,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              TextButton(onPressed: _dismiss, child: Text(context.l10n.cancel)),
              const SizedBox(height: 8),
              Text(
                context.l10n.voiceSearchServiceNotice,
                style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
