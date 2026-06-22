/// Discord Rich Presence config.
///
/// SETUP (one time): https://discord.com/developers/applications → New
/// Application → copy its **Application ID** into [applicationId] below. Upload
/// a square logo under Rich Presence → Art Assets named `logo` (that's the
/// small icon). Until [applicationId] is a real id, RPC stays disabled.
class DiscordConfig {
  DiscordConfig._();

  /// Zangetsu's Discord Application ID (Developer Portal → General Information).
  static const String applicationId = '1518610045422665748';

  /// Rich-Presence art-asset key for the small "app" icon (uploaded to the app).
  static const String appLogoAsset = 'logo';

  static const String appName = 'Zangetsu';

  /// Discord API base (v10).
  static const String api = 'https://discord.com/api/v10';

  static const String gatewayUrl =
      'wss://gateway.discord.gg/?v=10&encoding=json';

  /// True once a real Application ID has been set.
  static bool get configured =>
      applicationId.length >= 17 && applicationId != '0';
}
