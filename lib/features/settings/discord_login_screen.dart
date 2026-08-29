import 'package:flutter/material.dart';

import '../../core/platform/apple_tv.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/settings_widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Logs into Discord and captures the user token for Rich Presence.
///
/// Phone/tablet/Android TV: WebView login with a paste-token fallback.
/// Apple TV: WebView is unavailable — paste token only (from a browser on another device).
class DiscordLoginScreen extends StatelessWidget {
  const DiscordLoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (isAppleTv) return const _DiscordTokenPasteScreen();
    return const _DiscordWebLoginScreen();
  }
}

/// Apple TV — no [WebViewController] implementation on tvOS.
class _DiscordTokenPasteScreen extends StatefulWidget {
  const _DiscordTokenPasteScreen();

  @override
  State<_DiscordTokenPasteScreen> createState() => _DiscordTokenPasteScreenState();
}

class _DiscordTokenPasteScreenState extends State<_DiscordTokenPasteScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _save() {
    final token = _controller.text.trim();
    if (token.length <= 30) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paste a valid Discord user token')),
      );
      return;
    }
    Navigator.of(context).pop(token);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Connect Discord'),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          children: [
            Text(
              'Discord sign-in in a browser is not available on TV. '
              'On your phone or computer, log in at discord.com, copy your '
              'user token, then paste it below.',
              style: AppText.body,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              maxLines: 4,
              cursorColor: AppColors.accent,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                labelText: 'Discord user token',
                hintText: 'Paste token here',
                alignLabelWithHint: true,
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 24),
            TvFocusable(
              autofocus: true,
              variant: TvFocusVariant.pill,
              onTap: _save,
              semanticLabel: 'Save token',
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: Text(
                    'Save',
                    style: AppText.headline.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mobile / desktop WebView login with paste-token fallback in the app bar.
class _DiscordWebLoginScreen extends StatefulWidget {
  const _DiscordWebLoginScreen();

  @override
  State<_DiscordWebLoginScreen> createState() => _DiscordWebLoginScreenState();
}

class _DiscordWebLoginScreenState extends State<_DiscordWebLoginScreen> {
  late final WebViewController _controller;
  bool _grabbed = false;

  // Pulls the user token out of Discord's webpack store. Runs synchronously and
  // returns the token (or null). Only valid once the app page has loaded. Tries
  // several known module shapes since Discord changes them.
  static const String _grabber = '''
(function(){
  var token=null;
  function pick(ex){
    if(!ex)return null;
    try{
      if(ex.default&&typeof ex.default.getToken==='function')return ex.default.getToken();
      if(typeof ex.getToken==='function')return ex.getToken();
      if(ex.Z&&typeof ex.Z.getToken==='function')return ex.Z.getToken();
      if(ex.ZP&&typeof ex.ZP.getToken==='function')return ex.ZP.getToken();
    }catch(_){}
    return null;
  }
  try{
    var chunk=(window.webpackChunkdiscord_app=window.webpackChunkdiscord_app||[]);
    chunk.push([[Symbol('z')],{},function(req){
      try{
        for(var id in req.c){
          var t=pick(req.c[id]&&req.c[id].exports);
          if(t){token=t;return;}
        }
      }catch(_){}
    }]);
  }catch(_){}
  return token;
})()
''';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Desktop UA so Discord doesn't refuse the WebView login.
      ..setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      )
      // Primary capture: intercept the Authorization header Discord puts on its
      // own API calls (carries the user token). Far more robust than poking at
      // webpack internals (which Discord renames).
      ..addJavaScriptChannel(
        'ZToken',
        onMessageReceived: (m) => _onToken(m.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => _inject(),
          onPageFinished: (_) {
            _inject();
            _attemptGrab();
          },
        ),
      )
      ..loadRequest(Uri.parse('https://discord.com/login'));
  }

  /// Patch XHR/fetch to forward any Authorization header to [_onToken]. Idempotent.
  void _inject() {
    _controller.runJavaScript(_interceptor);
  }

  void _onToken(String raw) {
    final t = raw.trim().replaceAll('"', '');
    if (_grabbed || t.length < 40 || t.startsWith('Bearer')) return;
    _grabbed = true;
    if (mounted) Navigator.of(context).pop(t);
  }

  static const String _interceptor = '''
(function(){
  if(window.__zt)return; window.__zt=true;
  function send(v){try{if(!window.__zsent&&v&&v.length>40&&v.indexOf('Bearer')!==0){window.__zsent=true;ZToken.postMessage(v);}}catch(_){}}
  try{
    var s=XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader=function(k,v){
      try{if(k&&k.toLowerCase()==='authorization')send(v);}catch(_){}
      return s.apply(this,arguments);
    };
  }catch(_){}
  try{
    var f=window.fetch;
    window.fetch=function(){
      try{
        var o=arguments[1];
        if(o&&o.headers){
          var h=o.headers;
          var a=h.authorization||h.Authorization||(h.get&&h.get('authorization'));
          send(a);
        }
      }catch(_){}
      return f.apply(this,arguments);
    };
  }catch(_){}
})();
''';

  Future<void> _attemptGrab() async {
    if (_grabbed || !mounted) return;
    try {
      final raw = await _controller.runJavaScriptReturningResult(_grabber);
      final token = _clean(raw.toString());
      if (token != null && token.length > 30) {
        _grabbed = true;
        if (mounted) Navigator.of(context).pop(token);
      }
    } catch (_) {
      // webpack not ready yet — the header interceptor is the primary path.
    }
  }

  String? _clean(String raw) {
    var s = raw.trim();
    if (s == 'null' || s == 'undefined' || s.isEmpty) return null;
    if (s.startsWith('"') && s.endsWith('"')) s = s.substring(1, s.length - 1);
    s = s.replaceAll(r'\"', '"').replaceAll(r'\/', '/');
    return s == 'null' || s.isEmpty ? null : s;
  }

  Future<void> _pasteManually() async {
    final ctrl = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste Discord token'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Your Discord user token',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (token != null && token.length > 30 && mounted) {
      Navigator.of(context).pop(token);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: settingsAppBar(
        'Connect Discord',
        actions: [
          TextButton(
            onPressed: _pasteManually,
            child: const Text('Paste token'),
          ),
        ],
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
