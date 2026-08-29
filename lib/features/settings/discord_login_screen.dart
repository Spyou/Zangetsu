import 'package:flutter/material.dart';

import 'discord_web_login_screen.dart';

/// Logs into Discord and captures the user token for Rich Presence.
class DiscordLoginScreen extends StatelessWidget {
  const DiscordLoginScreen({super.key});

  @override
  Widget build(BuildContext context) => const DiscordWebLoginScreen();
}
