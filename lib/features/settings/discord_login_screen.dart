import 'package:flutter/material.dart';

import '../../core/platform/apple_tv.dart';
import 'discord_web_login_screen.dart';
import 'tv_discord_connect_screen.dart';

/// Logs into Discord and captures the user token for Rich Presence.
///
/// Phone/tablet/Android TV: WebView login with a paste-token fallback.
/// Apple TV: QR pairing — sign in on your phone and relay the token.
class DiscordLoginScreen extends StatelessWidget {
  const DiscordLoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (isAppleTv) return const TvDiscordConnectScreen();
    return const DiscordWebLoginScreen();
  }
}
