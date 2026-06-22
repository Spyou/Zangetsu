import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme/app_text.dart';

/// Logs into Discord in a WebView and captures the user token (so the Gateway
/// can set Rich Presence). Pops with the token string, or null if cancelled.
/// A "paste token" fallback covers the case where Discord blocks the WebView or
/// changes the token-grabber.
class DiscordLoginScreen extends StatefulWidget {
  const DiscordLoginScreen({super.key});

  @override
  State<DiscordLoginScreen> createState() => _DiscordLoginScreenState();
}

class _DiscordLoginScreenState extends State<DiscordLoginScreen> {
  late final WebViewController _controller;
  bool _grabbed = false;
  Timer? _poll;

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
          onUrlChange: (_) => _attemptGrab(),
        ),
      )
      ..loadRequest(Uri.parse('https://discord.com/login'));
    // Secondary: poll the webpack grabber (Discord is a SPA, so navigation
    // callbacks alone are unreliable).
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _attemptGrab());
  }

  /// Patch XHR/fetch to forward any Authorization header to [_onToken]. Idempotent.
  void _inject() {
    _controller.runJavaScript(_interceptor);
  }

  void _onToken(String raw) {
    final t = raw.trim().replaceAll('"', '');
    if (_grabbed || t.length < 40 || t.startsWith('Bearer')) return;
    _grabbed = true;
    _poll?.cancel();
    if (mounted) Navigator.of(context).pop(t);
  }

  static const String _interceptor = '''
(function(){
  if(window.__zt)return; window.__zt=true;
  function send(v){try{if(v&&v.length>40&&v.indexOf('Bearer')!==0)ZToken.postMessage(v);}catch(_){}}
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

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _attemptGrab() async {
    if (_grabbed || !mounted) return;
    try {
      final raw = await _controller.runJavaScriptReturningResult(_grabber);
      final token = _clean(raw.toString());
      if (token != null && token.length > 30) {
        _grabbed = true;
        _poll?.cancel();
        if (mounted) Navigator.of(context).pop(token);
      }
    } catch (_) {
      // webpack not ready / page not logged in yet — keep polling.
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
      appBar: AppBar(
        title: Text('Connect Discord', style: AppText.title),
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
