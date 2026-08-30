import 'package:flutter/material.dart';

import '../core/mode/content_mode.dart';
import '../core/models/watch_status.dart';
import '../core/playback/search_prefs.dart';
import '../core/playback/source_health_store.dart' show SourceOutcome;
import '../core/theme/theme_controller.dart';
import '../core/ui/nav_prefs.dart';
import 'app_localizations.dart';
import 'l10n.dart';

/// Localized dock tab label (phone bottom bar).
extension DockTabL10n on DockTab {
  String localizedLabel(BuildContext context) => switch (this) {
        DockTab.home => context.l10n.home,
        DockTab.schedule => context.l10n.schedule,
        DockTab.search => context.l10n.search,
        DockTab.myList => context.l10n.myList,
        DockTab.downloads => context.l10n.downloads,
        DockTab.history => context.l10n.history,
        DockTab.profile => context.l10n.profile,
      };
}

/// Localized search-results layout name.
extension SearchLayoutL10n on SearchLayout {
  String localizedLabel(BuildContext context) => switch (this) {
        SearchLayout.vertical => context.l10n.searchLayoutVertical,
        SearchLayout.horizontal => context.l10n.searchLayoutHorizontal,
      };
}

/// Localized content-mode switcher label.
extension ContentModeL10n on ContentMode {
  String localizedLabel(BuildContext context) =>
      contentModeLabel(context.l10n, this);
}

String contentModeLabel(AppLocalizations l10n, ContentMode mode) =>
    switch (mode) {
      ContentMode.anime => l10n.modeStreaming,
      ContentMode.manga => l10n.modeManga,
      ContentMode.novel => l10n.modeNovel,
    };

String contentModeContentNoun(AppLocalizations l10n, ContentMode mode) =>
    switch (mode) {
      ContentMode.anime => l10n.contentShows,
      ContentMode.manga => l10n.contentManga,
      ContentMode.novel => l10n.contentNovels,
    };

String sourceOutcomeLabel(AppLocalizations l10n, SourceOutcome outcome) =>
    switch (outcome) {
      SourceOutcome.timeout => l10n.sourceTimedOut,
      SourceOutcome.blocked => l10n.blockedByTheSite,
      _ => l10n.sourceCouldntBeReached,
    };

/// Settings hub section ids (stable; not shown to the user).
abstract final class SettingsSection {
  static const account = 'account';
  static const sources = 'sources';
  static const playback = 'playback';
  static const reading = 'reading';
  static const history = 'history';
  static const downloads = 'downloads';
  static const interface = 'interface';
  static const notifications = 'notifications';
  static const advanced = 'advanced';
  static const about = 'about';

  static const order = <String>[
    account,
    sources,
    playback,
    reading,
    history,
    downloads,
    interface,
    notifications,
    advanced,
    about,
  ];
}

String settingsSectionTitle(AppLocalizations l10n, String section) =>
    switch (section) {
      SettingsSection.account => l10n.settingsSectionAccount,
      SettingsSection.sources => l10n.settingsSectionSources,
      SettingsSection.playback => l10n.settingsSectionPlayback,
      SettingsSection.reading => l10n.settingsSectionReading,
      SettingsSection.history => l10n.settingsSectionHistory,
      SettingsSection.downloads => l10n.settingsSectionDownloads,
      SettingsSection.interface => l10n.settingsSectionInterface,
      SettingsSection.notifications => l10n.settingsSectionNotifications,
      SettingsSection.advanced => l10n.settingsSectionAdvanced,
      SettingsSection.about => l10n.settingsSectionAbout,
      _ => section,
    };

String settingsSectionSummary(AppLocalizations l10n, String section) =>
    switch (section) {
      SettingsSection.account => l10n.settingsSectionAccountSummary,
      SettingsSection.sources => l10n.settingsSectionSourcesSummary,
      SettingsSection.playback => l10n.settingsSectionPlaybackSummary,
      SettingsSection.reading => l10n.settingsSectionReadingSummary,
      SettingsSection.history => l10n.settingsSectionHistorySummary,
      SettingsSection.downloads => l10n.settingsSectionDownloadsSummary,
      SettingsSection.interface => l10n.settingsSectionInterfaceSummary,
      SettingsSection.notifications => l10n.settingsSectionNotificationsSummary,
      SettingsSection.advanced => l10n.settingsSectionAdvancedSummary,
      SettingsSection.about => l10n.settingsSectionAboutSummary,
      _ => '',
    };

IconData settingsSectionIcon(String section) => switch (section) {
      SettingsSection.account => Icons.person_outline_rounded,
      SettingsSection.sources => Icons.dns_rounded,
      SettingsSection.playback => Icons.play_circle_outline_rounded,
      SettingsSection.reading => Icons.menu_book_outlined,
      SettingsSection.history => Icons.history_rounded,
      SettingsSection.downloads => Icons.download_outlined,
      SettingsSection.interface => Icons.tune_rounded,
      SettingsSection.notifications => Icons.notifications_none_rounded,
      SettingsSection.advanced => Icons.build_outlined,
      SettingsSection.about => Icons.info_outline_rounded,
      _ => Icons.settings_outlined,
    };

/// Maps [ThemeController.accentLabel] (English) to localized strings.
String themeAccentLabel(AppLocalizations l10n) => switch (
      ThemeController.accentLabel) {
  'Wallpaper' => l10n.accentWallpaper,
  'Default' => l10n.defaultLabel,
  'Custom' => l10n.custom,
  final preset => accentPresetLabel(l10n, preset),
};

String accentPresetLabel(AppLocalizations l10n, String englishName) =>
    switch (englishName) {
      'Coral' => l10n.accentCoral,
      'Blue' => l10n.accentBlue,
      'Violet' => l10n.accentViolet,
      'Emerald' => l10n.accentEmerald,
      'Amber' => l10n.accentAmber,
      'Rose' => l10n.accentRose,
      'Cyan' => l10n.accentCyan,
      'Crimson' => l10n.accentCrimson,
      _ => englishName,
    };

String watchStatusLabel(
  AppLocalizations l10n,
  WatchStatus s, {
  required bool reading,
}) {
  if (!reading) {
    return switch (s) {
      WatchStatus.planning => l10n.statusPlanToWatch,
      WatchStatus.watching => l10n.statusWatching,
      WatchStatus.completed => l10n.statusCompleted,
      WatchStatus.paused => l10n.statusPaused,
      WatchStatus.dropped => l10n.statusDropped,
    };
  }
  return switch (s) {
    WatchStatus.watching => l10n.statusReading,
    WatchStatus.planning => l10n.statusPlanToRead,
    WatchStatus.completed => l10n.statusCompleted,
    WatchStatus.paused => l10n.statusPaused,
    WatchStatus.dropped => l10n.statusDropped,
  };
}

String watchStatusShortLabel(
  AppLocalizations l10n,
  WatchStatus s, {
  required bool reading,
}) {
  if (!reading) {
    return switch (s) {
      WatchStatus.planning => l10n.statusPlanning,
      WatchStatus.watching => l10n.statusWatching,
      WatchStatus.completed => l10n.statusCompleted,
      WatchStatus.paused => l10n.statusPaused,
      WatchStatus.dropped => l10n.statusDropped,
    };
  }
  return switch (s) {
    WatchStatus.watching => l10n.statusReading,
    WatchStatus.planning ||
    WatchStatus.completed ||
    WatchStatus.paused ||
    WatchStatus.dropped =>
      watchStatusShortLabel(l10n, s, reading: false),
  };
}

/// Maps known auth-cubit error strings to localized messages.
String? localizeAuthError(AppLocalizations l10n, String? error) {
  if (error == null) return null;
  return switch (error) {
    'Invalid email or password' => l10n.invalidEmailOrPassword,
    'Authentication failed' => l10n.authenticationFailed,
    'Could not reconnect' => l10n.couldNotReconnect,
    'Sign up failed' => l10n.signUpFailed,
    'Something went wrong' => l10n.somethingWentWrong,
    "Couldn't update photo" => l10n.couldntUpdatePhoto,
    _ => error,
  };
}

List<(String, String)> shaderStylePickerOptions(AppLocalizations l10n) => [
  ('off', l10n.shaderOff),
  ('a', l10n.shaderStyleSharpenClean),
  ('b', l10n.shaderStyleDeblurSoft),
  ('c', l10n.shaderStyleDenoiseGrainy),
];

List<(String, String)> shaderTierPickerOptions(AppLocalizations l10n) => [
  ('mid', l10n.shaderTierMidLight),
  ('high', l10n.shaderTierHighHeavy),
];

String shaderStylePickerLabel(AppLocalizations l10n, String id) {
  for (final (v, label) in shaderStylePickerOptions(l10n)) {
    if (v == id) return label;
  }
  return l10n.shaderOff;
}

String shaderTierPickerLabel(AppLocalizations l10n, String tier) {
  for (final (v, label) in shaderTierPickerOptions(l10n)) {
    if (v == tier) return label;
  }
  return l10n.shaderTierMidLight;
}

List<(String, String)> videoDecoderOptions(AppLocalizations l10n) => [
  ('copy', l10n.decoderHardwareRecommended),
  ('direct', l10n.decoderHardwareFaster),
  ('sw', l10n.decoderSoftwareCompatible),
  ('auto', l10n.decoderAuto),
];

List<(String, String)> videoRendererOptions(AppLocalizations l10n) => [
  ('auto', l10n.rendererAutoRecommended),
  ('gpu', l10n.rendererGpuStandard),
  ('gpu-next', l10n.rendererGpuNextExperimental),
  ('mediacodec_embed', l10n.rendererMediacodecEmbed),
];

List<(String, String)> closeConfirmPickerOptions(AppLocalizations l10n) => [
  ('double_back', l10n.closeConfirmDoubleBackLabel),
  ('confirm', l10n.closeConfirmAskLabel),
  ('direct', l10n.closeConfirmExitImmediatelyLabel),
];
