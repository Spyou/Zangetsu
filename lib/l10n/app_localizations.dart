import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_it.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('de'),
    Locale('es'),
    Locale('fr'),
    Locale('it'),
    Locale('ja'),
    Locale('zh'),
    Locale('zh', 'TW'),
  ];

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get off;

  /// No description provided for @on.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get on;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @yes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get yes;

  /// No description provided for @no.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get no;

  /// No description provided for @all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get all;

  /// No description provided for @none.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get none;

  /// No description provided for @auto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get auto;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @install.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get install;

  /// No description provided for @uninstall.
  ///
  /// In en, this message translates to:
  /// **'Uninstall'**
  String get uninstall;

  /// No description provided for @reset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get reset;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @resume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get resume;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @update.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get update;

  /// No description provided for @apply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get apply;

  /// No description provided for @enable.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get enable;

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @move.
  ///
  /// In en, this message translates to:
  /// **'Move'**
  String get move;

  /// No description provided for @join.
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get join;

  /// No description provided for @leave.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get leave;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @later.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get later;

  /// No description provided for @dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @more.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get more;

  /// No description provided for @info.
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get info;

  /// No description provided for @filter.
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get filter;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signIn;

  /// No description provided for @logOut.
  ///
  /// In en, this message translates to:
  /// **'Log out'**
  String get logOut;

  /// No description provided for @tryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get tryAgain;

  /// No description provided for @showDetails.
  ///
  /// In en, this message translates to:
  /// **'Show details'**
  String get showDetails;

  /// No description provided for @hideDetails.
  ///
  /// In en, this message translates to:
  /// **'Hide details'**
  String get hideDetails;

  /// No description provided for @notNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get notNow;

  /// No description provided for @change.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get change;

  /// No description provided for @go.
  ///
  /// In en, this message translates to:
  /// **'Go'**
  String get go;

  /// No description provided for @read.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get read;

  /// No description provided for @web.
  ///
  /// In en, this message translates to:
  /// **'Web'**
  String get web;

  /// No description provided for @live.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get live;

  /// No description provided for @sub.
  ///
  /// In en, this message translates to:
  /// **'Sub'**
  String get sub;

  /// No description provided for @dub.
  ///
  /// In en, this message translates to:
  /// **'Dub'**
  String get dub;

  /// No description provided for @nsfw.
  ///
  /// In en, this message translates to:
  /// **'NSFW'**
  String get nsfw;

  /// No description provided for @system.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get system;

  /// No description provided for @custom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get custom;

  /// No description provided for @defaultLabel.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get defaultLabel;

  /// No description provided for @selected.
  ///
  /// In en, this message translates to:
  /// **'selected'**
  String get selected;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get loading;

  /// No description provided for @searching.
  ///
  /// In en, this message translates to:
  /// **'Searching'**
  String get searching;

  /// No description provided for @searchingEllipsis.
  ///
  /// In en, this message translates to:
  /// **'searching…'**
  String get searchingEllipsis;

  /// No description provided for @downloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get downloading;

  /// No description provided for @updating.
  ///
  /// In en, this message translates to:
  /// **'Updating…'**
  String get updating;

  /// No description provided for @testing.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get testing;

  /// No description provided for @working.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get working;

  /// No description provided for @dead.
  ///
  /// In en, this message translates to:
  /// **'Dead'**
  String get dead;

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;

  /// No description provided for @appLanguage.
  ///
  /// In en, this message translates to:
  /// **'App language'**
  String get appLanguage;

  /// No description provided for @appLanguageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Interface language'**
  String get appLanguageSubtitle;

  /// No description provided for @appLanguageSystem.
  ///
  /// In en, this message translates to:
  /// **'System (auto)'**
  String get appLanguageSystem;

  /// No description provided for @appLanguageSystemSubtitle.
  ///
  /// In en, this message translates to:
  /// **'System ({name})'**
  String appLanguageSystemSubtitle(String name);

  /// No description provided for @appLanguageKeywords.
  ///
  /// In en, this message translates to:
  /// **'language locale translation i18n interface japanese chinese spanish german french italian'**
  String get appLanguageKeywords;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search settings'**
  String get settingsSearchHint;

  /// No description provided for @settingsNoMatch.
  ///
  /// In en, this message translates to:
  /// **'No settings match \"{query}\"'**
  String settingsNoMatch(String query);

  /// No description provided for @settingsSectionAccount.
  ///
  /// In en, this message translates to:
  /// **'Account & sync'**
  String get settingsSectionAccount;

  /// No description provided for @settingsSectionSources.
  ///
  /// In en, this message translates to:
  /// **'Sources'**
  String get settingsSectionSources;

  /// No description provided for @settingsSectionPlayback.
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get settingsSectionPlayback;

  /// No description provided for @settingsSectionReading.
  ///
  /// In en, this message translates to:
  /// **'Reading'**
  String get settingsSectionReading;

  /// No description provided for @settingsSectionHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get settingsSectionHistory;

  /// No description provided for @settingsSectionDownloads.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get settingsSectionDownloads;

  /// No description provided for @settingsSectionInterface.
  ///
  /// In en, this message translates to:
  /// **'Interface'**
  String get settingsSectionInterface;

  /// No description provided for @settingsSectionNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsSectionNotifications;

  /// No description provided for @settingsSectionAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get settingsSectionAdvanced;

  /// No description provided for @settingsSectionAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsSectionAbout;

  /// No description provided for @settingsSectionAccountSummary.
  ///
  /// In en, this message translates to:
  /// **'Trackers, Discord, backup, sync'**
  String get settingsSectionAccountSummary;

  /// No description provided for @settingsSectionSourcesSummary.
  ///
  /// In en, this message translates to:
  /// **'Providers, active source, updates'**
  String get settingsSectionSourcesSummary;

  /// No description provided for @settingsSectionPlaybackSummary.
  ///
  /// In en, this message translates to:
  /// **'Quality, autoplay, speed'**
  String get settingsSectionPlaybackSummary;

  /// No description provided for @settingsSectionReadingSummary.
  ///
  /// In en, this message translates to:
  /// **'Manga & novel reader defaults'**
  String get settingsSectionReadingSummary;

  /// No description provided for @settingsSectionHistorySummary.
  ///
  /// In en, this message translates to:
  /// **'Shows you\'ve watched'**
  String get settingsSectionHistorySummary;

  /// No description provided for @settingsSectionDownloadsSummary.
  ///
  /// In en, this message translates to:
  /// **'Downloads, storage, torrents'**
  String get settingsSectionDownloadsSummary;

  /// No description provided for @settingsSectionInterfaceSummary.
  ///
  /// In en, this message translates to:
  /// **'Appearance, language, search layout'**
  String get settingsSectionInterfaceSummary;

  /// No description provided for @settingsSectionNotificationsSummary.
  ///
  /// In en, this message translates to:
  /// **'New-episode alerts'**
  String get settingsSectionNotificationsSummary;

  /// No description provided for @settingsSectionAdvancedSummary.
  ///
  /// In en, this message translates to:
  /// **'DNS, privacy, logs'**
  String get settingsSectionAdvancedSummary;

  /// No description provided for @settingsSectionAboutSummary.
  ///
  /// In en, this message translates to:
  /// **'Updates, support, version'**
  String get settingsSectionAboutSummary;

  /// No description provided for @couldNotExportLogs.
  ///
  /// In en, this message translates to:
  /// **'Could not export logs'**
  String get couldNotExportLogs;

  /// No description provided for @logsShareSubject.
  ///
  /// In en, this message translates to:
  /// **'Zangetsu logs'**
  String get logsShareSubject;

  /// No description provided for @signInSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync your list, history & continue watching'**
  String get signInSubtitle;

  /// No description provided for @signInSubtitleTv.
  ///
  /// In en, this message translates to:
  /// **'Sync your list & continue watching'**
  String get signInSubtitleTv;

  /// No description provided for @connections.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get connections;

  /// No description provided for @discord.
  ///
  /// In en, this message translates to:
  /// **'Discord'**
  String get discord;

  /// No description provided for @discordSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Rich Presence — show your status'**
  String get discordSubtitle;

  /// No description provided for @watchParty.
  ///
  /// In en, this message translates to:
  /// **'Watch Party'**
  String get watchParty;

  /// No description provided for @watchPartySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create or join a watch party with friends'**
  String get watchPartySubtitle;

  /// No description provided for @signInToWatchTogether.
  ///
  /// In en, this message translates to:
  /// **'Sign in to watch together'**
  String get signInToWatchTogether;

  /// No description provided for @syncLibraryToCloud.
  ///
  /// In en, this message translates to:
  /// **'Sync library to cloud'**
  String get syncLibraryToCloud;

  /// No description provided for @syncLibraryToCloudSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Re-upload history & list to this account'**
  String get syncLibraryToCloudSubtitle;

  /// No description provided for @signInFirst.
  ///
  /// In en, this message translates to:
  /// **'Sign in first'**
  String get signInFirst;

  /// No description provided for @reconnectToSyncLibrary.
  ///
  /// In en, this message translates to:
  /// **'Reconnect to sync your library.'**
  String get reconnectToSyncLibrary;

  /// No description provided for @syncingLibraryToCloud.
  ///
  /// In en, this message translates to:
  /// **'Syncing your library to cloud…'**
  String get syncingLibraryToCloud;

  /// No description provided for @backupAndRestore.
  ///
  /// In en, this message translates to:
  /// **'Backup & Restore'**
  String get backupAndRestore;

  /// No description provided for @backupAndRestoreSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Save your sources, list & settings'**
  String get backupAndRestoreSubtitle;

  /// No description provided for @providers.
  ///
  /// In en, this message translates to:
  /// **'Providers'**
  String get providers;

  /// No description provided for @providersEnabledCount.
  ///
  /// In en, this message translates to:
  /// **'{count} enabled'**
  String providersEnabledCount(int count);

  /// No description provided for @activeSource.
  ///
  /// In en, this message translates to:
  /// **'Active source'**
  String get activeSource;

  /// No description provided for @sourceHealth.
  ///
  /// In en, this message translates to:
  /// **'Source health'**
  String get sourceHealth;

  /// No description provided for @sourceHealthSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Test which sources are working'**
  String get sourceHealthSubtitle;

  /// No description provided for @sourceUpdates.
  ///
  /// In en, this message translates to:
  /// **'Source updates'**
  String get sourceUpdates;

  /// No description provided for @sourceUpdatesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Notify when installed sources have updates'**
  String get sourceUpdatesSubtitle;

  /// No description provided for @autoUpdateExtensions.
  ///
  /// In en, this message translates to:
  /// **'Auto-update extensions'**
  String get autoUpdateExtensions;

  /// No description provided for @autoUpdateExtensionsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Update installed sources automatically on launch'**
  String get autoUpdateExtensionsSubtitle;

  /// No description provided for @playback.
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get playback;

  /// No description provided for @playbackSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Quality, autoplay, speed'**
  String get playbackSubtitle;

  /// No description provided for @reader.
  ///
  /// In en, this message translates to:
  /// **'Reader'**
  String get reader;

  /// No description provided for @readerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Manga & novel reading defaults'**
  String get readerSubtitle;

  /// No description provided for @history.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get history;

  /// No description provided for @historySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Shows you\'ve watched'**
  String get historySubtitle;

  /// No description provided for @downloads.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get downloads;

  /// No description provided for @downloadsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Manage your downloaded episodes'**
  String get downloadsSubtitle;

  /// No description provided for @downloadsSubtitleTv.
  ///
  /// In en, this message translates to:
  /// **'Watch offline'**
  String get downloadsSubtitleTv;

  /// No description provided for @storage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get storage;

  /// No description provided for @storageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Manage space used by the app'**
  String get storageSubtitle;

  /// No description provided for @torrents.
  ///
  /// In en, this message translates to:
  /// **'Torrents'**
  String get torrents;

  /// No description provided for @torrentsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Streaming & data settings'**
  String get torrentsSubtitle;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @appearanceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Accent colour, poster badges'**
  String get appearanceSubtitle;

  /// No description provided for @searchLayout.
  ///
  /// In en, this message translates to:
  /// **'Search layout'**
  String get searchLayout;

  /// No description provided for @searchLayoutSubtitle.
  ///
  /// In en, this message translates to:
  /// **'How cross-source results are shown'**
  String get searchLayoutSubtitle;

  /// No description provided for @searchLayoutBlurb.
  ///
  /// In en, this message translates to:
  /// **'How cross-source results are shown. Vertical = a grid per source; Horizontal = a scrolling row per source.'**
  String get searchLayoutBlurb;

  /// No description provided for @searchLayoutVertical.
  ///
  /// In en, this message translates to:
  /// **'Vertical (grid)'**
  String get searchLayoutVertical;

  /// No description provided for @searchLayoutHorizontal.
  ///
  /// In en, this message translates to:
  /// **'Horizontal (rows)'**
  String get searchLayoutHorizontal;

  /// No description provided for @batchDownloadStyle.
  ///
  /// In en, this message translates to:
  /// **'Batch download style'**
  String get batchDownloadStyle;

  /// No description provided for @batchDownloadStyleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'How the multi-episode sheet looks'**
  String get batchDownloadStyleSubtitle;

  /// No description provided for @batchDownloadStyleBlurb.
  ///
  /// In en, this message translates to:
  /// **'The sheet shown when you download a whole season. Both download exactly the same — only the picker looks different.'**
  String get batchDownloadStyleBlurb;

  /// No description provided for @batchDownloadClassic.
  ///
  /// In en, this message translates to:
  /// **'Classic'**
  String get batchDownloadClassic;

  /// No description provided for @batchDownloadClassicBlurb.
  ///
  /// In en, this message translates to:
  /// **'The full sheet with a per-episode thumbnail grid.'**
  String get batchDownloadClassicBlurb;

  /// No description provided for @batchDownloadMinimal.
  ///
  /// In en, this message translates to:
  /// **'Minimal'**
  String get batchDownloadMinimal;

  /// No description provided for @batchDownloadMinimalBlurb.
  ///
  /// In en, this message translates to:
  /// **'A number wheel — pick how many episodes to grab.'**
  String get batchDownloadMinimalBlurb;

  /// No description provided for @notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// No description provided for @notificationsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'New-episode alerts for subscribed shows'**
  String get notificationsSubtitle;

  /// No description provided for @dns.
  ///
  /// In en, this message translates to:
  /// **'DNS'**
  String get dns;

  /// No description provided for @dnsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Bypass ISP blocks on CS sources'**
  String get dnsSubtitle;

  /// No description provided for @dnsBlurb.
  ///
  /// In en, this message translates to:
  /// **'Encrypted DNS for CloudStream sources — helps bypass ISP blocking. Off = your normal connection.'**
  String get dnsBlurb;

  /// No description provided for @dnsOffTvSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Off · bypass ISP blocks on CS sources'**
  String get dnsOffTvSubtitle;

  /// No description provided for @privacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get privacy;

  /// No description provided for @privacySubtitle.
  ///
  /// In en, this message translates to:
  /// **'NSFW sources'**
  String get privacySubtitle;

  /// No description provided for @shareLogs.
  ///
  /// In en, this message translates to:
  /// **'Share logs'**
  String get shareLogs;

  /// No description provided for @shareLogsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Send a diagnostic log to help fix an issue'**
  String get shareLogsSubtitle;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @versionLabel.
  ///
  /// In en, this message translates to:
  /// **'v{version}'**
  String versionLabel(String version);

  /// No description provided for @contributors.
  ///
  /// In en, this message translates to:
  /// **'Contributors'**
  String get contributors;

  /// No description provided for @website.
  ///
  /// In en, this message translates to:
  /// **'Website'**
  String get website;

  /// No description provided for @communityChat.
  ///
  /// In en, this message translates to:
  /// **'Community chat'**
  String get communityChat;

  /// No description provided for @joinTheServer.
  ///
  /// In en, this message translates to:
  /// **'Join the server'**
  String get joinTheServer;

  /// No description provided for @viewTheSourceCode.
  ///
  /// In en, this message translates to:
  /// **'View the source code'**
  String get viewTheSourceCode;

  /// No description provided for @howItWorks.
  ///
  /// In en, this message translates to:
  /// **'How it works'**
  String get howItWorks;

  /// No description provided for @howItWorksSubtitle.
  ///
  /// In en, this message translates to:
  /// **'New here? A quick guide'**
  String get howItWorksSubtitle;

  /// No description provided for @checkForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get checkForUpdates;

  /// No description provided for @checkForUpdatesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Get the latest version from GitHub'**
  String get checkForUpdatesSubtitle;

  /// No description provided for @checkingForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Checking for updates…'**
  String get checkingForUpdates;

  /// No description provided for @betaUpdates.
  ///
  /// In en, this message translates to:
  /// **'Beta updates'**
  String get betaUpdates;

  /// No description provided for @betaUpdatesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Get pre-release builds early — may be unstable'**
  String get betaUpdatesSubtitle;

  /// No description provided for @supportTheApp.
  ///
  /// In en, this message translates to:
  /// **'Support the app'**
  String get supportTheApp;

  /// No description provided for @buyMeACoffee.
  ///
  /// In en, this message translates to:
  /// **'Buy me a coffee'**
  String get buyMeACoffee;

  /// No description provided for @leadDeveloper.
  ///
  /// In en, this message translates to:
  /// **'Lead Developer'**
  String get leadDeveloper;

  /// No description provided for @addCloudStreamRepository.
  ///
  /// In en, this message translates to:
  /// **'Add CloudStream repository'**
  String get addCloudStreamRepository;

  /// No description provided for @installCloudStreamSources.
  ///
  /// In en, this message translates to:
  /// **'Install CloudStream sources'**
  String get installCloudStreamSources;

  /// No description provided for @connectionsTvSubtitle.
  ///
  /// In en, this message translates to:
  /// **'AniList, MyAnimeList, Simkl'**
  String get connectionsTvSubtitle;

  /// No description provided for @profile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profile;

  /// No description provided for @home.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get home;

  /// No description provided for @myList.
  ///
  /// In en, this message translates to:
  /// **'My List'**
  String get myList;

  /// No description provided for @schedule.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get schedule;

  /// No description provided for @pressBackAgainToExit.
  ///
  /// In en, this message translates to:
  /// **'Press BACK again to exit'**
  String get pressBackAgainToExit;

  /// No description provided for @pressBackAgainToExitTv.
  ///
  /// In en, this message translates to:
  /// **'Press back again to exit'**
  String get pressBackAgainToExitTv;

  /// No description provided for @selectSource.
  ///
  /// In en, this message translates to:
  /// **'Select Source'**
  String get selectSource;

  /// No description provided for @accentWallpaper.
  ///
  /// In en, this message translates to:
  /// **'Wallpaper'**
  String get accentWallpaper;

  /// No description provided for @accentCoral.
  ///
  /// In en, this message translates to:
  /// **'Coral'**
  String get accentCoral;

  /// No description provided for @accentBlue.
  ///
  /// In en, this message translates to:
  /// **'Blue'**
  String get accentBlue;

  /// No description provided for @accentViolet.
  ///
  /// In en, this message translates to:
  /// **'Violet'**
  String get accentViolet;

  /// No description provided for @accentEmerald.
  ///
  /// In en, this message translates to:
  /// **'Emerald'**
  String get accentEmerald;

  /// No description provided for @accentAmber.
  ///
  /// In en, this message translates to:
  /// **'Amber'**
  String get accentAmber;

  /// No description provided for @accentRose.
  ///
  /// In en, this message translates to:
  /// **'Rose'**
  String get accentRose;

  /// No description provided for @accentCyan.
  ///
  /// In en, this message translates to:
  /// **'Cyan'**
  String get accentCyan;

  /// No description provided for @accentCrimson.
  ///
  /// In en, this message translates to:
  /// **'Crimson'**
  String get accentCrimson;

  /// No description provided for @shaderOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get shaderOff;

  /// No description provided for @shaderOffDesc.
  ///
  /// In en, this message translates to:
  /// **'No enhancement'**
  String get shaderOffDesc;

  /// No description provided for @shaderSharpen.
  ///
  /// In en, this message translates to:
  /// **'Sharpen'**
  String get shaderSharpen;

  /// No description provided for @shaderSharpenDesc.
  ///
  /// In en, this message translates to:
  /// **'Restore detail — best for clean sources'**
  String get shaderSharpenDesc;

  /// No description provided for @shaderDeblur.
  ///
  /// In en, this message translates to:
  /// **'De-blur'**
  String get shaderDeblur;

  /// No description provided for @shaderDeblurDesc.
  ///
  /// In en, this message translates to:
  /// **'Softer restore — for blurry / soft sources'**
  String get shaderDeblurDesc;

  /// No description provided for @shaderDenoise.
  ///
  /// In en, this message translates to:
  /// **'Denoise'**
  String get shaderDenoise;

  /// No description provided for @shaderDenoiseDesc.
  ///
  /// In en, this message translates to:
  /// **'Clean up grain — for compressed sources'**
  String get shaderDenoiseDesc;

  /// No description provided for @shaderTierHigh.
  ///
  /// In en, this message translates to:
  /// **'High-end GPU'**
  String get shaderTierHigh;

  /// No description provided for @shaderTierHighDesc.
  ///
  /// In en, this message translates to:
  /// **'Heavier VL upscalers + HQ scaling — needs a strong GPU'**
  String get shaderTierHighDesc;

  /// No description provided for @shaderTierMid.
  ///
  /// In en, this message translates to:
  /// **'Mid-range GPU'**
  String get shaderTierMid;

  /// No description provided for @shaderTierMidDesc.
  ///
  /// In en, this message translates to:
  /// **'Light upscalers + deband — smooth on most phones'**
  String get shaderTierMidDesc;

  /// No description provided for @playerInfoResolution.
  ///
  /// In en, this message translates to:
  /// **'Resolution'**
  String get playerInfoResolution;

  /// No description provided for @playerInfoSource.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get playerInfoSource;

  /// No description provided for @playerInfoQuality.
  ///
  /// In en, this message translates to:
  /// **'Quality'**
  String get playerInfoQuality;

  /// No description provided for @playerInfoVideoCodec.
  ///
  /// In en, this message translates to:
  /// **'Video codec'**
  String get playerInfoVideoCodec;

  /// No description provided for @playerInfoAudioCodec.
  ///
  /// In en, this message translates to:
  /// **'Audio codec'**
  String get playerInfoAudioCodec;

  /// No description provided for @playerInfoFrameRate.
  ///
  /// In en, this message translates to:
  /// **'Frame rate'**
  String get playerInfoFrameRate;

  /// No description provided for @playerInfoVideoBitrate.
  ///
  /// In en, this message translates to:
  /// **'Video bitrate'**
  String get playerInfoVideoBitrate;

  /// No description provided for @playerInfoBuffer.
  ///
  /// In en, this message translates to:
  /// **'Buffer'**
  String get playerInfoBuffer;

  /// No description provided for @playerInfoDroppedFrames.
  ///
  /// In en, this message translates to:
  /// **'Dropped frames'**
  String get playerInfoDroppedFrames;

  /// No description provided for @playerInfoDecoder.
  ///
  /// In en, this message translates to:
  /// **'Decoder'**
  String get playerInfoDecoder;

  /// No description provided for @playerInfoSpeed.
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get playerInfoSpeed;

  /// No description provided for @playerInfoAudioTrack.
  ///
  /// In en, this message translates to:
  /// **'Audio track'**
  String get playerInfoAudioTrack;

  /// No description provided for @playerInfoSubtitleTrack.
  ///
  /// In en, this message translates to:
  /// **'Subtitle track'**
  String get playerInfoSubtitleTrack;

  /// No description provided for @playerInfoAudioBoost.
  ///
  /// In en, this message translates to:
  /// **'Audio boost'**
  String get playerInfoAudioBoost;

  /// No description provided for @statusPlanToWatch.
  ///
  /// In en, this message translates to:
  /// **'Plan to Watch'**
  String get statusPlanToWatch;

  /// No description provided for @statusWatching.
  ///
  /// In en, this message translates to:
  /// **'Watching'**
  String get statusWatching;

  /// No description provided for @statusCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get statusCompleted;

  /// No description provided for @statusPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get statusPaused;

  /// No description provided for @statusDropped.
  ///
  /// In en, this message translates to:
  /// **'Dropped'**
  String get statusDropped;

  /// No description provided for @statusPlanning.
  ///
  /// In en, this message translates to:
  /// **'Planning'**
  String get statusPlanning;

  /// No description provided for @statusReading.
  ///
  /// In en, this message translates to:
  /// **'Reading'**
  String get statusReading;

  /// No description provided for @statusPlanToRead.
  ///
  /// In en, this message translates to:
  /// **'Plan to Read'**
  String get statusPlanToRead;

  /// No description provided for @modeStreaming.
  ///
  /// In en, this message translates to:
  /// **'Streaming'**
  String get modeStreaming;

  /// No description provided for @modeManga.
  ///
  /// In en, this message translates to:
  /// **'Manga'**
  String get modeManga;

  /// No description provided for @modeNovel.
  ///
  /// In en, this message translates to:
  /// **'Novel'**
  String get modeNovel;

  /// No description provided for @relativeToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get relativeToday;

  /// No description provided for @relativeYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get relativeYesterday;

  /// No description provided for @relativeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {{count} day ago} other {{count} days ago}}'**
  String relativeDaysAgo(int count);

  /// No description provided for @relativeWeeksAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {{count} week ago} other {{count} weeks ago}}'**
  String relativeWeeksAgo(int count);

  /// No description provided for @relativeMonthsAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {{count} month ago} other {{count} months ago}}'**
  String relativeMonthsAgo(int count);

  /// No description provided for @relativeYearsAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {{count} year ago} other {{count} years ago}}'**
  String relativeYearsAgo(int count);

  /// No description provided for @bootErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Zangetsu didn\'t finish starting'**
  String get bootErrorTitle;

  /// No description provided for @bootErrorBody.
  ///
  /// In en, this message translates to:
  /// **'Something saved on this device is stopping it from opening. Nothing is lost — your account and anything synced to the cloud are safe.'**
  String get bootErrorBody;

  /// No description provided for @resetAppData.
  ///
  /// In en, this message translates to:
  /// **'Reset app data'**
  String get resetAppData;

  /// No description provided for @resetAppDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset app data?'**
  String get resetAppDataTitle;

  /// No description provided for @resetAppDataBody.
  ///
  /// In en, this message translates to:
  /// **'This clears what Zangetsu has saved on this device so it can start fresh.\n\nYour account and anything synced to the cloud are not touched — sign in again and your library comes back.'**
  String get resetAppDataBody;

  /// No description provided for @resetAppDataDone.
  ///
  /// In en, this message translates to:
  /// **'Close Zangetsu completely and open it again.'**
  String get resetAppDataDone;

  /// No description provided for @detailsCopied.
  ///
  /// In en, this message translates to:
  /// **'Details copied — send them to us'**
  String get detailsCopied;

  /// No description provided for @copyDetails.
  ///
  /// In en, this message translates to:
  /// **'Copy details'**
  String get copyDetails;

  /// No description provided for @goodToHaveYouHere.
  ///
  /// In en, this message translates to:
  /// **'Good to have you here.'**
  String get goodToHaveYouHere;

  /// No description provided for @onboardingIntro.
  ///
  /// In en, this message translates to:
  /// **'Anime, manga and novels — all in one app, set up your way.'**
  String get onboardingIntro;

  /// No description provided for @youChooseWhatsInside.
  ///
  /// In en, this message translates to:
  /// **'You choose what\'s inside'**
  String get youChooseWhatsInside;

  /// No description provided for @addTheSourcesYouWant.
  ///
  /// In en, this message translates to:
  /// **'Add the sources you want — here\'s how.'**
  String get addTheSourcesYouWant;

  /// No description provided for @openProviders.
  ///
  /// In en, this message translates to:
  /// **'Open Providers'**
  String get openProviders;

  /// No description provided for @pickStreamingMangaOrNovels.
  ///
  /// In en, this message translates to:
  /// **'Pick streaming, manga or novels'**
  String get pickStreamingMangaOrNovels;

  /// No description provided for @pasteInARepositoryLink.
  ///
  /// In en, this message translates to:
  /// **'Paste in a repository link'**
  String get pasteInARepositoryLink;

  /// No description provided for @browseAndGrab.
  ///
  /// In en, this message translates to:
  /// **'Browse it and grab what looks good'**
  String get browseAndGrab;

  /// No description provided for @readyWhenYouAre.
  ///
  /// In en, this message translates to:
  /// **'Ready when you are.'**
  String get readyWhenYouAre;

  /// No description provided for @addSourcesNow.
  ///
  /// In en, this message translates to:
  /// **'Add sources now'**
  String get addSourcesNow;

  /// No description provided for @illDoItLater.
  ///
  /// In en, this message translates to:
  /// **'I\'ll do it later'**
  String get illDoItLater;

  /// No description provided for @howToUseTheApp.
  ///
  /// In en, this message translates to:
  /// **'How to use the app'**
  String get howToUseTheApp;

  /// No description provided for @aFewTapsToAnything.
  ///
  /// In en, this message translates to:
  /// **'A few taps to anything.'**
  String get aFewTapsToAnything;

  /// No description provided for @findSomething.
  ///
  /// In en, this message translates to:
  /// **'Find something'**
  String get findSomething;

  /// No description provided for @watchIt.
  ///
  /// In en, this message translates to:
  /// **'Watch it'**
  String get watchIt;

  /// No description provided for @ifItWontLoad.
  ///
  /// In en, this message translates to:
  /// **'If it won\'t load'**
  String get ifItWontLoad;

  /// No description provided for @saveForOffline.
  ///
  /// In en, this message translates to:
  /// **'Save for offline'**
  String get saveForOffline;

  /// No description provided for @commonQuestions.
  ///
  /// In en, this message translates to:
  /// **'Common questions'**
  String get commonQuestions;

  /// No description provided for @noCommunityContributorsYet.
  ///
  /// In en, this message translates to:
  /// **'No community contributors yet.'**
  String get noCommunityContributorsYet;

  /// No description provided for @paged.
  ///
  /// In en, this message translates to:
  /// **'Paged'**
  String get paged;

  /// No description provided for @vertical.
  ///
  /// In en, this message translates to:
  /// **'Vertical'**
  String get vertical;

  /// No description provided for @tapZonesReset.
  ///
  /// In en, this message translates to:
  /// **'Tap zones reset'**
  String get tapZonesReset;

  /// No description provided for @noUPIAppFoundUPIIDCopiedPasteItInYourUPIApp.
  ///
  /// In en, this message translates to:
  /// **'No UPI app found — UPI ID copied, paste it in your UPI app'**
  String get noUPIAppFoundUPIIDCopiedPasteItInYourUPIApp;

  /// No description provided for @donateWithPayPal.
  ///
  /// In en, this message translates to:
  /// **'Donate with PayPal'**
  String get donateWithPayPal;

  /// No description provided for @payViaUPI.
  ///
  /// In en, this message translates to:
  /// **'Pay via UPI'**
  String get payViaUPI;

  /// No description provided for @copyUPIID.
  ///
  /// In en, this message translates to:
  /// **'Copy UPI ID'**
  String get copyUPIID;

  /// No description provided for @readingMode.
  ///
  /// In en, this message translates to:
  /// **'Reading mode'**
  String get readingMode;

  /// No description provided for @fit.
  ///
  /// In en, this message translates to:
  /// **'Fit'**
  String get fit;

  /// No description provided for @background.
  ///
  /// In en, this message translates to:
  /// **'Background'**
  String get background;

  /// No description provided for @colourFilter.
  ///
  /// In en, this message translates to:
  /// **'Colour filter'**
  String get colourFilter;

  /// No description provided for @orientationLock.
  ///
  /// In en, this message translates to:
  /// **'Orientation lock'**
  String get orientationLock;

  /// No description provided for @doublePageLandscape.
  ///
  /// In en, this message translates to:
  /// **'Double-page (landscape)'**
  String get doublePageLandscape;

  /// No description provided for @pairFacingPagesInALandscapeSpread.
  ///
  /// In en, this message translates to:
  /// **'Pair facing pages in a landscape spread'**
  String get pairFacingPagesInALandscapeSpread;

  /// No description provided for @cropBorders.
  ///
  /// In en, this message translates to:
  /// **'Crop borders'**
  String get cropBorders;

  /// No description provided for @trimNearUniformEdgeMarginsFromAPage.
  ///
  /// In en, this message translates to:
  /// **'Trim near-uniform edge margins from a page'**
  String get trimNearUniformEdgeMarginsFromAPage;

  /// No description provided for @preloadPages.
  ///
  /// In en, this message translates to:
  /// **'Preload pages'**
  String get preloadPages;

  /// No description provided for @keepScreenOn.
  ///
  /// In en, this message translates to:
  /// **'Keep screen on'**
  String get keepScreenOn;

  /// No description provided for @tapZones.
  ///
  /// In en, this message translates to:
  /// **'Tap zones'**
  String get tapZones;

  /// No description provided for @whatTappingEachPartOfThePageDoes.
  ///
  /// In en, this message translates to:
  /// **'What tapping each part of the page does'**
  String get whatTappingEachPartOfThePageDoes;

  /// No description provided for @font.
  ///
  /// In en, this message translates to:
  /// **'Font'**
  String get font;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @fontSize.
  ///
  /// In en, this message translates to:
  /// **'Font size'**
  String get fontSize;

  /// No description provided for @lineHeight.
  ///
  /// In en, this message translates to:
  /// **'Line height'**
  String get lineHeight;

  /// No description provided for @margin.
  ///
  /// In en, this message translates to:
  /// **'Margin'**
  String get margin;

  /// No description provided for @justifyText.
  ///
  /// In en, this message translates to:
  /// **'Justify text'**
  String get justifyText;

  /// No description provided for @textDirection.
  ///
  /// In en, this message translates to:
  /// **'Text direction'**
  String get textDirection;

  /// No description provided for @paragraphSpacing.
  ///
  /// In en, this message translates to:
  /// **'Paragraph spacing'**
  String get paragraphSpacing;

  /// No description provided for @paginated.
  ///
  /// In en, this message translates to:
  /// **'Paginated'**
  String get paginated;

  /// No description provided for @bookStylePagesInsteadOfAContinuousScroll.
  ///
  /// In en, this message translates to:
  /// **'Book-style pages instead of a continuous scroll'**
  String get bookStylePagesInsteadOfAContinuousScroll;

  /// No description provided for @enableNSFWSources.
  ///
  /// In en, this message translates to:
  /// **'Enable NSFW sources?'**
  String get enableNSFWSources;

  /// No description provided for @showNSFWAniyomiSources.
  ///
  /// In en, this message translates to:
  /// **'Show NSFW Aniyomi sources?'**
  String get showNSFWAniyomiSources;

  /// No description provided for @incognitoMode.
  ///
  /// In en, this message translates to:
  /// **'Incognito mode'**
  String get incognitoMode;

  /// No description provided for @pauseHistoryTrackingDiscordPresence.
  ///
  /// In en, this message translates to:
  /// **'Pause history, tracking & Discord presence'**
  String get pauseHistoryTrackingDiscordPresence;

  /// No description provided for @enableNSFWSources2.
  ///
  /// In en, this message translates to:
  /// **'Enable NSFW sources'**
  String get enableNSFWSources2;

  /// No description provided for @showSourcesMarked18.
  ///
  /// In en, this message translates to:
  /// **'Show sources marked 18+'**
  String get showSourcesMarked18;

  /// No description provided for @showNSFWSources.
  ///
  /// In en, this message translates to:
  /// **'Show NSFW sources'**
  String get showNSFWSources;

  /// No description provided for @adultAniyomiExtensions.
  ///
  /// In en, this message translates to:
  /// **'Adult Aniyomi extensions'**
  String get adultAniyomiExtensions;

  /// No description provided for @opensubtitlesAPIKey.
  ///
  /// In en, this message translates to:
  /// **'OpenSubtitles API key'**
  String get opensubtitlesAPIKey;

  /// No description provided for @pasteYourKey.
  ///
  /// In en, this message translates to:
  /// **'Paste your key'**
  String get pasteYourKey;

  /// No description provided for @createAFreeKeyAtOpensubtitlesComConsumers.
  ///
  /// In en, this message translates to:
  /// **'Create a free key at opensubtitles.com → Consumers.'**
  String get createAFreeKeyAtOpensubtitlesComConsumers;

  /// No description provided for @shaderDownloadFailedCheckNetwork.
  ///
  /// In en, this message translates to:
  /// **'Shader download failed — check network'**
  String get shaderDownloadFailedCheckNetwork;

  /// No description provided for @anime4kEnhancement.
  ///
  /// In en, this message translates to:
  /// **'Anime4K Enhancement'**
  String get anime4kEnhancement;

  /// No description provided for @anime4kGPUTier.
  ///
  /// In en, this message translates to:
  /// **'Anime4K GPU tier'**
  String get anime4kGPUTier;

  /// No description provided for @cacheCleared.
  ///
  /// In en, this message translates to:
  /// **'Cache cleared'**
  String get cacheCleared;

  /// No description provided for @videoBufferSize.
  ///
  /// In en, this message translates to:
  /// **'Video buffer size'**
  String get videoBufferSize;

  /// No description provided for @videoBufferLength.
  ///
  /// In en, this message translates to:
  /// **'Video buffer length'**
  String get videoBufferLength;

  /// No description provided for @playerInfoOverlay.
  ///
  /// In en, this message translates to:
  /// **'Player info overlay'**
  String get playerInfoOverlay;

  /// No description provided for @defaultQuality.
  ///
  /// In en, this message translates to:
  /// **'Default quality'**
  String get defaultQuality;

  /// No description provided for @videoDecoder.
  ///
  /// In en, this message translates to:
  /// **'Video decoder'**
  String get videoDecoder;

  /// No description provided for @videoRenderer.
  ///
  /// In en, this message translates to:
  /// **'Video renderer'**
  String get videoRenderer;

  /// No description provided for @defaultAudio.
  ///
  /// In en, this message translates to:
  /// **'Default audio'**
  String get defaultAudio;

  /// No description provided for @defaultSpeed.
  ///
  /// In en, this message translates to:
  /// **'Default speed'**
  String get defaultSpeed;

  /// No description provided for @doubleTapSkip.
  ///
  /// In en, this message translates to:
  /// **'Double-tap skip'**
  String get doubleTapSkip;

  /// No description provided for @closeConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Close confirmation'**
  String get closeConfirmation;

  /// No description provided for @megaskipDuration.
  ///
  /// In en, this message translates to:
  /// **'MegaSkip duration'**
  String get megaskipDuration;

  /// No description provided for @defaultPlayer.
  ///
  /// In en, this message translates to:
  /// **'Default player'**
  String get defaultPlayer;

  /// No description provided for @defaultAudioAnimeSubDub.
  ///
  /// In en, this message translates to:
  /// **'Default audio (anime sub/dub)'**
  String get defaultAudioAnimeSubDub;

  /// No description provided for @builtIn.
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get builtIn;

  /// No description provided for @playerControls.
  ///
  /// In en, this message translates to:
  /// **'Player controls'**
  String get playerControls;

  /// No description provided for @reorderOrHideTheButtonsOnThePlayerBar.
  ///
  /// In en, this message translates to:
  /// **'Reorder or hide the buttons on the player bar'**
  String get reorderOrHideTheButtonsOnThePlayerBar;

  /// No description provided for @resumePlayback.
  ///
  /// In en, this message translates to:
  /// **'Resume playback'**
  String get resumePlayback;

  /// No description provided for @continueFromWhereYouLeftOff.
  ///
  /// In en, this message translates to:
  /// **'Continue from where you left off'**
  String get continueFromWhereYouLeftOff;

  /// No description provided for @askBeforeJumping.
  ///
  /// In en, this message translates to:
  /// **'Ask before jumping'**
  String get askBeforeJumping;

  /// No description provided for @autoAddToMyList.
  ///
  /// In en, this message translates to:
  /// **'Auto-add to My List'**
  String get autoAddToMyList;

  /// No description provided for @addATitleToMyListWhenYouStartWatchingIt.
  ///
  /// In en, this message translates to:
  /// **'Add a title to My List when you start watching it'**
  String get addATitleToMyListWhenYouStartWatchingIt;

  /// No description provided for @autoTrack.
  ///
  /// In en, this message translates to:
  /// **'Auto-track'**
  String get autoTrack;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'confirm'**
  String get confirm;

  /// No description provided for @autoplayNextEpisode.
  ///
  /// In en, this message translates to:
  /// **'Autoplay next episode'**
  String get autoplayNextEpisode;

  /// No description provided for @autoSkipFillerEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Auto-skip filler episodes'**
  String get autoSkipFillerEpisodes;

  /// No description provided for @autoplayTrailer.
  ///
  /// In en, this message translates to:
  /// **'Autoplay trailer'**
  String get autoplayTrailer;

  /// No description provided for @playATitleSTrailerOnItsDetailPage.
  ///
  /// In en, this message translates to:
  /// **'Play a title\'s trailer on its detail page'**
  String get playATitleSTrailerOnItsDetailPage;

  /// No description provided for @playTrailersInHD.
  ///
  /// In en, this message translates to:
  /// **'Play trailers in HD'**
  String get playTrailersInHD;

  /// No description provided for @skipIntroButton.
  ///
  /// In en, this message translates to:
  /// **'Skip intro button'**
  String get skipIntroButton;

  /// No description provided for @showSkipOpeningEndingOnAnimeWhenDetected.
  ///
  /// In en, this message translates to:
  /// **'Show Skip opening/ending on anime (when detected)'**
  String get showSkipOpeningEndingOnAnimeWhenDetected;

  /// No description provided for @autoSkipOpening.
  ///
  /// In en, this message translates to:
  /// **'Auto-skip opening'**
  String get autoSkipOpening;

  /// No description provided for @jumpPastTheOPOnItsOwnNoTap.
  ///
  /// In en, this message translates to:
  /// **'Jump past the OP on its own, no tap'**
  String get jumpPastTheOPOnItsOwnNoTap;

  /// No description provided for @autoSkipRecap.
  ///
  /// In en, this message translates to:
  /// **'Auto-skip recap'**
  String get autoSkipRecap;

  /// No description provided for @jumpPastThePreviouslyOnRecapNoTap.
  ///
  /// In en, this message translates to:
  /// **'Jump past the \"previously on\" recap, no tap'**
  String get jumpPastThePreviouslyOnRecapNoTap;

  /// No description provided for @autoSkipEnding.
  ///
  /// In en, this message translates to:
  /// **'Auto-skip ending'**
  String get autoSkipEnding;

  /// No description provided for @jumpPastTheEDOnItsOwnNoTap.
  ///
  /// In en, this message translates to:
  /// **'Jump past the ED on its own, no tap'**
  String get jumpPastTheEDOnItsOwnNoTap;

  /// No description provided for @megaskipButton.
  ///
  /// In en, this message translates to:
  /// **'MegaSkip button'**
  String get megaskipButton;

  /// No description provided for @aJumpForwardButtonInThePlayerAnyVideo.
  ///
  /// In en, this message translates to:
  /// **'A jump-forward button in the player (any video)'**
  String get aJumpForwardButtonInThePlayerAnyVideo;

  /// No description provided for @nativeTVPlayer.
  ///
  /// In en, this message translates to:
  /// **'Native TV player'**
  String get nativeTVPlayer;

  /// No description provided for @softwareAudioDolbyDTS.
  ///
  /// In en, this message translates to:
  /// **'Software audio (Dolby/DTS)'**
  String get softwareAudioDolbyDTS;

  /// No description provided for @seekPreviewOnline.
  ///
  /// In en, this message translates to:
  /// **'Seek preview (online)'**
  String get seekPreviewOnline;

  /// No description provided for @thumbnailsWhileScrubbingStreamsCostsExtraData.
  ///
  /// In en, this message translates to:
  /// **'Thumbnails while scrubbing streams — costs extra data'**
  String get thumbnailsWhileScrubbingStreamsCostsExtraData;

  /// No description provided for @autoPictureInPicture.
  ///
  /// In en, this message translates to:
  /// **'Auto picture-in-picture'**
  String get autoPictureInPicture;

  /// No description provided for @shrinkToAFloatingWindowWhenYouLeaveTheApp.
  ///
  /// In en, this message translates to:
  /// **'Shrink to a floating window when you leave the app'**
  String get shrinkToAFloatingWindowWhenYouLeaveTheApp;

  /// No description provided for @showQualityLabel.
  ///
  /// In en, this message translates to:
  /// **'Show quality label'**
  String get showQualityLabel;

  /// No description provided for @plainQualityTextEG1080pOnTheTopBarRight.
  ///
  /// In en, this message translates to:
  /// **'Plain quality text (e.g. 1080p) on the top-bar right'**
  String get plainQualityTextEG1080pOnTheTopBarRight;

  /// No description provided for @gestureControls.
  ///
  /// In en, this message translates to:
  /// **'Gesture controls'**
  String get gestureControls;

  /// No description provided for @swipeLeftForBrightnessRightForVolume.
  ///
  /// In en, this message translates to:
  /// **'Swipe left for brightness, right for volume'**
  String get swipeLeftForBrightnessRightForVolume;

  /// No description provided for @swipeToSeek.
  ///
  /// In en, this message translates to:
  /// **'Swipe to seek'**
  String get swipeToSeek;

  /// No description provided for @dragLeftOrRightAcrossTheVideoToScrub.
  ///
  /// In en, this message translates to:
  /// **'Drag left or right across the video to scrub'**
  String get dragLeftOrRightAcrossTheVideoToScrub;

  /// No description provided for @holdFor2Speed.
  ///
  /// In en, this message translates to:
  /// **'Hold for 2× speed'**
  String get holdFor2Speed;

  /// No description provided for @longPressTheVideoToPlayAt2WhileHeld.
  ///
  /// In en, this message translates to:
  /// **'Long-press the video to play at 2× while held'**
  String get longPressTheVideoToPlayAt2WhileHeld;

  /// No description provided for @clearImageVideoCache.
  ///
  /// In en, this message translates to:
  /// **'Clear image & video cache'**
  String get clearImageVideoCache;

  /// No description provided for @styledSubtitlesLibass.
  ///
  /// In en, this message translates to:
  /// **'Styled subtitles (libass)'**
  String get styledSubtitlesLibass;

  /// No description provided for @subtitleStyle.
  ///
  /// In en, this message translates to:
  /// **'Subtitle style'**
  String get subtitleStyle;

  /// No description provided for @requiredForOnlineSubtitleSearch.
  ///
  /// In en, this message translates to:
  /// **'Required for online subtitle search'**
  String get requiredForOnlineSubtitleSearch;

  /// No description provided for @subtitleLanguage.
  ///
  /// In en, this message translates to:
  /// **'Subtitle language'**
  String get subtitleLanguage;

  /// No description provided for @autoDownloadSubtitles.
  ///
  /// In en, this message translates to:
  /// **'Auto-download subtitles'**
  String get autoDownloadSubtitles;

  /// No description provided for @whenTheSourceHasNoSubtitleInYourLanguage.
  ///
  /// In en, this message translates to:
  /// **'When the source has no subtitle in your language'**
  String get whenTheSourceHasNoSubtitleInYourLanguage;

  /// No description provided for @autoTranslateSubtitles.
  ///
  /// In en, this message translates to:
  /// **'Auto-translate subtitles'**
  String get autoTranslateSubtitles;

  /// No description provided for @translateToYourLanguageOnPlayWhenTheSourceHasNone.
  ///
  /// In en, this message translates to:
  /// **'Translate to your language on play (when the source has none)'**
  String get translateToYourLanguageOnPlayWhenTheSourceHasNone;

  /// No description provided for @translateSubtitlesTo.
  ///
  /// In en, this message translates to:
  /// **'Translate subtitles to'**
  String get translateSubtitlesTo;

  /// No description provided for @pickALanguage.
  ///
  /// In en, this message translates to:
  /// **'Pick a language'**
  String get pickALanguage;

  /// No description provided for @customColour.
  ///
  /// In en, this message translates to:
  /// **'Custom colour'**
  String get customColour;

  /// No description provided for @materialYou.
  ///
  /// In en, this message translates to:
  /// **'Material You'**
  String get materialYou;

  /// No description provided for @coloursFromYourWallpaper.
  ///
  /// In en, this message translates to:
  /// **'Colours from your wallpaper'**
  String get coloursFromYourWallpaper;

  /// No description provided for @pureBlackBackground.
  ///
  /// In en, this message translates to:
  /// **'Pure black background'**
  String get pureBlackBackground;

  /// No description provided for @trueBlackForOLED.
  ///
  /// In en, this message translates to:
  /// **'True black for OLED'**
  String get trueBlackForOLED;

  /// No description provided for @posterBadges.
  ///
  /// In en, this message translates to:
  /// **'Poster badges'**
  String get posterBadges;

  /// No description provided for @qualityAndSubDubBadges.
  ///
  /// In en, this message translates to:
  /// **'Quality and Sub/Dub badges'**
  String get qualityAndSubDubBadges;

  /// No description provided for @animateLists.
  ///
  /// In en, this message translates to:
  /// **'Animate lists'**
  String get animateLists;

  /// No description provided for @cardsFadeInAsYouScroll.
  ///
  /// In en, this message translates to:
  /// **'Cards fade in as you scroll'**
  String get cardsFadeInAsYouScroll;

  /// No description provided for @animationStyle.
  ///
  /// In en, this message translates to:
  /// **'Animation style'**
  String get animationStyle;

  /// No description provided for @turnOffMaterialYouToPickAColourYourself.
  ///
  /// In en, this message translates to:
  /// **'Turn off Material You to pick a colour yourself'**
  String get turnOffMaterialYouToPickAColourYourself;

  /// No description provided for @downloadsZangetsu.
  ///
  /// In en, this message translates to:
  /// **'Downloads › Zangetsu'**
  String get downloadsZangetsu;

  /// No description provided for @removableDrive.
  ///
  /// In en, this message translates to:
  /// **'Removable drive'**
  String get removableDrive;

  /// No description provided for @chooseFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose folder…'**
  String get chooseFolder;

  /// No description provided for @resetToDefault.
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get resetToDefault;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @imageCacheCleared.
  ///
  /// In en, this message translates to:
  /// **'Image cache cleared'**
  String get imageCacheCleared;

  /// No description provided for @providerCacheCleared.
  ///
  /// In en, this message translates to:
  /// **'Provider cache cleared'**
  String get providerCacheCleared;

  /// No description provided for @clearImageCache.
  ///
  /// In en, this message translates to:
  /// **'Clear image cache'**
  String get clearImageCache;

  /// No description provided for @clearProviderCache.
  ///
  /// In en, this message translates to:
  /// **'Clear provider cache'**
  String get clearProviderCache;

  /// No description provided for @showTitleE2.
  ///
  /// In en, this message translates to:
  /// **'Show title · E2'**
  String get showTitleE2;

  /// No description provided for @pinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get pinned;

  /// No description provided for @exoplayerSpikeDev.
  ///
  /// In en, this message translates to:
  /// **'ExoPlayer spike (dev)'**
  String get exoplayerSpikeDev;

  /// No description provided for @sp0TestSurfaceViewPlaybackSmoothness.
  ///
  /// In en, this message translates to:
  /// **'SP0 — test SurfaceView playback smoothness'**
  String get sp0TestSurfaceViewPlaybackSmoothness;

  /// No description provided for @pasteDiscordToken.
  ///
  /// In en, this message translates to:
  /// **'Paste Discord token'**
  String get pasteDiscordToken;

  /// No description provided for @yourDiscordUserToken.
  ///
  /// In en, this message translates to:
  /// **'Your Discord user token'**
  String get yourDiscordUserToken;

  /// No description provided for @pasteToken.
  ///
  /// In en, this message translates to:
  /// **'Paste token'**
  String get pasteToken;

  /// No description provided for @useMobileDataForTorrents.
  ///
  /// In en, this message translates to:
  /// **'Use mobile data for torrents'**
  String get useMobileDataForTorrents;

  /// No description provided for @discordConnected.
  ///
  /// In en, this message translates to:
  /// **'Discord connected'**
  String get discordConnected;

  /// No description provided for @disconnectDiscord.
  ///
  /// In en, this message translates to:
  /// **'Disconnect Discord?'**
  String get disconnectDiscord;

  /// No description provided for @notConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not configured'**
  String get notConfigured;

  /// No description provided for @aDiscordApplicationIDMustBeSetInTheBuildFirst.
  ///
  /// In en, this message translates to:
  /// **'A Discord Application ID must be set in the build first.'**
  String get aDiscordApplicationIDMustBeSetInTheBuildFirst;

  /// No description provided for @richPresence.
  ///
  /// In en, this message translates to:
  /// **'Rich Presence'**
  String get richPresence;

  /// No description provided for @showWhatYouReWatchingOnYourProfile.
  ///
  /// In en, this message translates to:
  /// **'Show what you\'re watching on your profile'**
  String get showWhatYouReWatchingOnYourProfile;

  /// No description provided for @signInToLinkYourAccount.
  ///
  /// In en, this message translates to:
  /// **'Sign in to link your account'**
  String get signInToLinkYourAccount;

  /// No description provided for @autoSync.
  ///
  /// In en, this message translates to:
  /// **'Auto-sync'**
  String get autoSync;

  /// No description provided for @disconnectingHereOnlySignsThisTrackerOutOnTheTVYourPhoneStaysConnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting here only signs this tracker out on the TV — your phone stays connected.'**
  String
  get disconnectingHereOnlySignsThisTrackerOutOnTheTVYourPhoneStaysConnected;

  /// No description provided for @continueWatching.
  ///
  /// In en, this message translates to:
  /// **'Continue Watching'**
  String get continueWatching;

  /// No description provided for @continueReading.
  ///
  /// In en, this message translates to:
  /// **'Continue Reading'**
  String get continueReading;

  /// No description provided for @seeAll.
  ///
  /// In en, this message translates to:
  /// **'See all'**
  String get seeAll;

  /// No description provided for @libraryLabel.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get libraryLabel;

  /// No description provided for @sortBy.
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get sortBy;

  /// No description provided for @newCategory.
  ///
  /// In en, this message translates to:
  /// **'New category'**
  String get newCategory;

  /// No description provided for @personaGym.
  ///
  /// In en, this message translates to:
  /// **'Persona, Gym, …'**
  String get personaGym;

  /// No description provided for @deleteCategory.
  ///
  /// In en, this message translates to:
  /// **'Delete category'**
  String get deleteCategory;

  /// No description provided for @yourTitlesStayOnlyTheLabelGoes.
  ///
  /// In en, this message translates to:
  /// **'Your titles stay — only the label goes'**
  String get yourTitlesStayOnlyTheLabelGoes;

  /// No description provided for @renameCategory.
  ///
  /// In en, this message translates to:
  /// **'Rename category'**
  String get renameCategory;

  /// No description provided for @manageTrackers.
  ///
  /// In en, this message translates to:
  /// **'Manage trackers'**
  String get manageTrackers;

  /// No description provided for @trackers.
  ///
  /// In en, this message translates to:
  /// **'Trackers'**
  String get trackers;

  /// No description provided for @showLabel.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get showLabel;

  /// No description provided for @couldnTLoadPullToRefresh.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t load — pull to refresh'**
  String get couldnTLoadPullToRefresh;

  /// No description provided for @noTitlesInThisList.
  ///
  /// In en, this message translates to:
  /// **'No titles in this list'**
  String get noTitlesInThisList;

  /// No description provided for @signInToBuildYourList.
  ///
  /// In en, this message translates to:
  /// **'Sign in to build your list'**
  String get signInToBuildYourList;

  /// No description provided for @titlesYouAddAppearHere.
  ///
  /// In en, this message translates to:
  /// **'Titles you add appear here'**
  String get titlesYouAddAppearHere;

  /// No description provided for @couldnTLoadTryAgainFromSettings.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t load — try again from Settings'**
  String get couldnTLoadTryAgainFromSettings;

  /// No description provided for @search2.
  ///
  /// In en, this message translates to:
  /// **'Search…'**
  String get search2;

  /// No description provided for @voiceSearch.
  ///
  /// In en, this message translates to:
  /// **'Voice search'**
  String get voiceSearch;

  /// No description provided for @allSources.
  ///
  /// In en, this message translates to:
  /// **'All sources'**
  String get allSources;

  /// No description provided for @currentSource.
  ///
  /// In en, this message translates to:
  /// **'Current source'**
  String get currentSource;

  /// No description provided for @searchFailedTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Search failed — try again'**
  String get searchFailedTryAgain;

  /// No description provided for @searchForSomethingToWatch.
  ///
  /// In en, this message translates to:
  /// **'Search for something to watch'**
  String get searchForSomethingToWatch;

  /// No description provided for @recentSearches.
  ///
  /// In en, this message translates to:
  /// **'Recent searches'**
  String get recentSearches;

  /// No description provided for @clearSearchHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear search history'**
  String get clearSearchHistory;

  /// No description provided for @checkTheSpellingOrTryADifferentTitle.
  ///
  /// In en, this message translates to:
  /// **'Check the spelling or try a different title.'**
  String get checkTheSpellingOrTryADifferentTitle;

  /// No description provided for @browseSources.
  ///
  /// In en, this message translates to:
  /// **'Browse sources'**
  String get browseSources;

  /// No description provided for @thisSourceHasNoFilters.
  ///
  /// In en, this message translates to:
  /// **'This source has no filters'**
  String get thisSourceHasNoFilters;

  /// No description provided for @searchIn.
  ///
  /// In en, this message translates to:
  /// **'Search in'**
  String get searchIn;

  /// No description provided for @filters.
  ///
  /// In en, this message translates to:
  /// **'Filters'**
  String get filters;

  /// No description provided for @sourceFilters.
  ///
  /// In en, this message translates to:
  /// **'Source filters'**
  String get sourceFilters;

  /// No description provided for @clearFilters.
  ///
  /// In en, this message translates to:
  /// **'Clear filters'**
  String get clearFilters;

  /// No description provided for @topPicks.
  ///
  /// In en, this message translates to:
  /// **'Top picks'**
  String get topPicks;

  /// No description provided for @anime.
  ///
  /// In en, this message translates to:
  /// **'Anime'**
  String get anime;

  /// No description provided for @moviesSeries.
  ///
  /// In en, this message translates to:
  /// **'Movies & Series'**
  String get moviesSeries;

  /// No description provided for @noSourcesInstalled.
  ///
  /// In en, this message translates to:
  /// **'No sources installed'**
  String get noSourcesInstalled;

  /// No description provided for @fromYourResults.
  ///
  /// In en, this message translates to:
  /// **'· from your results'**
  String get fromYourResults;

  /// No description provided for @any.
  ///
  /// In en, this message translates to:
  /// **'Any'**
  String get any;

  /// No description provided for @someSourcesDonTProvideGenres.
  ///
  /// In en, this message translates to:
  /// **'some sources don\'t provide genres'**
  String get someSourcesDonTProvideGenres;

  /// No description provided for @searchInSources.
  ///
  /// In en, this message translates to:
  /// **'Search in sources'**
  String get searchInSources;

  /// No description provided for @turnAllOff.
  ///
  /// In en, this message translates to:
  /// **'Turn all off'**
  String get turnAllOff;

  /// No description provided for @extensionsUpdated.
  ///
  /// In en, this message translates to:
  /// **'Extensions updated'**
  String get extensionsUpdated;

  /// No description provided for @incognito.
  ///
  /// In en, this message translates to:
  /// **'Incognito'**
  String get incognito;

  /// No description provided for @reconnectToSync.
  ///
  /// In en, this message translates to:
  /// **'Reconnect to sync'**
  String get reconnectToSync;

  /// No description provided for @yourSessionExpiredTapToSignInAndSyncYourLibrary.
  ///
  /// In en, this message translates to:
  /// **'Your session expired — tap to sign in and sync your library.'**
  String get yourSessionExpiredTapToSignInAndSyncYourLibrary;

  /// No description provided for @solveCloudflare.
  ///
  /// In en, this message translates to:
  /// **'Solve Cloudflare'**
  String get solveCloudflare;

  /// No description provided for @moviesTV.
  ///
  /// In en, this message translates to:
  /// **'Movies & TV'**
  String get moviesTV;

  /// No description provided for @couldnTLoadComingSoonPullToRefresh.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load coming soon — pull to refresh.'**
  String get couldnTLoadComingSoonPullToRefresh;

  /// No description provided for @streamURL.
  ///
  /// In en, this message translates to:
  /// **'Stream URL'**
  String get streamURL;

  /// No description provided for @exoplayerSurfaceViewSpikeSP0.
  ///
  /// In en, this message translates to:
  /// **'ExoPlayer SurfaceView spike (SP0)'**
  String get exoplayerSurfaceViewSpikeSP0;

  /// No description provided for @episodes.
  ///
  /// In en, this message translates to:
  /// **'Episodes'**
  String get episodes;

  /// No description provided for @season.
  ///
  /// In en, this message translates to:
  /// **'Season'**
  String get season;

  /// No description provided for @jumpToEpisode.
  ///
  /// In en, this message translates to:
  /// **'Jump to episode…'**
  String get jumpToEpisode;

  /// No description provided for @preferredLanguage.
  ///
  /// In en, this message translates to:
  /// **'Preferred language…'**
  String get preferredLanguage;

  /// No description provided for @searchOnline.
  ///
  /// In en, this message translates to:
  /// **'Search online…'**
  String get searchOnline;

  /// No description provided for @onlineSubtitles.
  ///
  /// In en, this message translates to:
  /// **'Online subtitles'**
  String get onlineSubtitles;

  /// No description provided for @audioSubs.
  ///
  /// In en, this message translates to:
  /// **'Audio & Subs'**
  String get audioSubs;

  /// No description provided for @nextEpisode.
  ///
  /// In en, this message translates to:
  /// **'Next Episode'**
  String get nextEpisode;

  /// No description provided for @colour.
  ///
  /// In en, this message translates to:
  /// **'Colour'**
  String get colour;

  /// No description provided for @snapshot.
  ///
  /// In en, this message translates to:
  /// **'Snapshot'**
  String get snapshot;

  /// No description provided for @sleepTimer.
  ///
  /// In en, this message translates to:
  /// **'Sleep timer'**
  String get sleepTimer;

  /// No description provided for @pictureInPicture.
  ///
  /// In en, this message translates to:
  /// **'Picture-in-picture'**
  String get pictureInPicture;

  /// No description provided for @cast.
  ///
  /// In en, this message translates to:
  /// **'Cast'**
  String get cast;

  /// No description provided for @playbackStats.
  ///
  /// In en, this message translates to:
  /// **'Playback stats'**
  String get playbackStats;

  /// No description provided for @sleepTimerOn.
  ///
  /// In en, this message translates to:
  /// **'Sleep timer on'**
  String get sleepTimerOn;

  /// No description provided for @lockControls.
  ///
  /// In en, this message translates to:
  /// **'Lock controls'**
  String get lockControls;

  /// No description provided for @chat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get chat;

  /// No description provided for @previousEpisode.
  ///
  /// In en, this message translates to:
  /// **'Previous episode'**
  String get previousEpisode;

  /// No description provided for @nextEpisode2.
  ///
  /// In en, this message translates to:
  /// **'Next episode'**
  String get nextEpisode2;

  /// No description provided for @translated.
  ///
  /// In en, this message translates to:
  /// **'Translated'**
  String get translated;

  /// No description provided for @thisSourceCanTBeCastTryAnotherSource.
  ///
  /// In en, this message translates to:
  /// **'This source can\'t be cast — try another source.'**
  String get thisSourceCanTBeCastTryAnotherSource;

  /// No description provided for @rewind10Seconds.
  ///
  /// In en, this message translates to:
  /// **'Rewind 10 seconds'**
  String get rewind10Seconds;

  /// No description provided for @forward10Seconds.
  ///
  /// In en, this message translates to:
  /// **'Forward 10 seconds'**
  String get forward10Seconds;

  /// No description provided for @stopCasting.
  ///
  /// In en, this message translates to:
  /// **'Stop casting'**
  String get stopCasting;

  /// No description provided for @usingTheBuiltInPlayerForThisSource.
  ///
  /// In en, this message translates to:
  /// **'Using the built-in player for this source.'**
  String get usingTheBuiltInPlayerForThisSource;

  /// No description provided for @closeVideo.
  ///
  /// In en, this message translates to:
  /// **'Close video?'**
  String get closeVideo;

  /// No description provided for @areYouSureYouWantToCloseTheVideo.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to close the video?'**
  String get areYouSureYouWantToCloseTheVideo;

  /// No description provided for @downloadInSettings.
  ///
  /// In en, this message translates to:
  /// **'Download in Settings'**
  String get downloadInSettings;

  /// No description provided for @getTheAnime4KShaders06MBThenTurnItOn.
  ///
  /// In en, this message translates to:
  /// **'Get the Anime4K shaders (~0.6 MB), then turn it on'**
  String get getTheAnime4KShaders06MBThenTurnItOn;

  /// No description provided for @gpuTIER.
  ///
  /// In en, this message translates to:
  /// **'GPU TIER'**
  String get gpuTIER;

  /// No description provided for @endOfEpisode.
  ///
  /// In en, this message translates to:
  /// **'End of episode'**
  String get endOfEpisode;

  /// No description provided for @closeAppWhenTimerEnds.
  ///
  /// In en, this message translates to:
  /// **'Close app when timer ends'**
  String get closeAppWhenTimerEnds;

  /// No description provided for @exitTheAppToSaveBattery.
  ///
  /// In en, this message translates to:
  /// **'Exit the app to save battery'**
  String get exitTheAppToSaveBattery;

  /// No description provided for @playNow.
  ///
  /// In en, this message translates to:
  /// **'Play now'**
  String get playNow;

  /// No description provided for @skipRecap.
  ///
  /// In en, this message translates to:
  /// **'Skip recap'**
  String get skipRecap;

  /// No description provided for @unlockControls.
  ///
  /// In en, this message translates to:
  /// **'Unlock controls'**
  String get unlockControls;

  /// No description provided for @tapToUnlock.
  ///
  /// In en, this message translates to:
  /// **'Tap to unlock'**
  String get tapToUnlock;

  /// No description provided for @subtitleDelay.
  ///
  /// In en, this message translates to:
  /// **'Subtitle delay'**
  String get subtitleDelay;

  /// No description provided for @audioDelay.
  ///
  /// In en, this message translates to:
  /// **'Audio delay'**
  String get audioDelay;

  /// No description provided for @audioNormalization.
  ///
  /// In en, this message translates to:
  /// **'Audio normalization'**
  String get audioNormalization;

  /// No description provided for @searchSubtitlesOnline.
  ///
  /// In en, this message translates to:
  /// **'Search subtitles online'**
  String get searchSubtitlesOnline;

  /// No description provided for @loadFromFile.
  ///
  /// In en, this message translates to:
  /// **'Load from file…'**
  String get loadFromFile;

  /// No description provided for @translateSubtitles.
  ///
  /// In en, this message translates to:
  /// **'Translate subtitles…'**
  String get translateSubtitles;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language:'**
  String get language;

  /// No description provided for @movieOrShowTitle.
  ///
  /// In en, this message translates to:
  /// **'Movie or show title'**
  String get movieOrShowTitle;

  /// No description provided for @theQuickBrownFox.
  ///
  /// In en, this message translates to:
  /// **'The quick brown fox'**
  String get theQuickBrownFox;

  /// No description provided for @seekBar.
  ///
  /// In en, this message translates to:
  /// **'Seek bar'**
  String get seekBar;

  /// No description provided for @autoScrollSettings.
  ///
  /// In en, this message translates to:
  /// **'Auto-scroll settings'**
  String get autoScrollSettings;

  /// No description provided for @autoScroll.
  ///
  /// In en, this message translates to:
  /// **'Auto-scroll'**
  String get autoScroll;

  /// No description provided for @touchThePageToPauseItPicksUpAgainWhenYouLetGo.
  ///
  /// In en, this message translates to:
  /// **'Touch the page to pause — it picks up again when you let go.'**
  String get touchThePageToPauseItPicksUpAgainWhenYouLetGo;

  /// No description provided for @floatingButton.
  ///
  /// In en, this message translates to:
  /// **'Floating button'**
  String get floatingButton;

  /// No description provided for @nextChapter.
  ///
  /// In en, this message translates to:
  /// **'Next chapter'**
  String get nextChapter;

  /// No description provided for @orKeepPulling.
  ///
  /// In en, this message translates to:
  /// **'or keep pulling'**
  String get orKeepPulling;

  /// No description provided for @thatSTheLastChapter.
  ///
  /// In en, this message translates to:
  /// **'That\'s the last chapter.'**
  String get thatSTheLastChapter;

  /// No description provided for @readerSettings.
  ///
  /// In en, this message translates to:
  /// **'Reader settings'**
  String get readerSettings;

  /// No description provided for @noOtherChaptersLoadedYet.
  ///
  /// In en, this message translates to:
  /// **'No other chapters loaded yet'**
  String get noOtherChaptersLoadedYet;

  /// No description provided for @chapters.
  ///
  /// In en, this message translates to:
  /// **'Chapters'**
  String get chapters;

  /// No description provided for @direction.
  ///
  /// In en, this message translates to:
  /// **'Direction'**
  String get direction;

  /// No description provided for @autoWebtoonMode.
  ///
  /// In en, this message translates to:
  /// **'Auto webtoon mode'**
  String get autoWebtoonMode;

  /// No description provided for @pullToChangeChapter.
  ///
  /// In en, this message translates to:
  /// **'Pull to change chapter'**
  String get pullToChangeChapter;

  /// No description provided for @volumeKeysTurnPages.
  ///
  /// In en, this message translates to:
  /// **'Volume keys turn pages'**
  String get volumeKeysTurnPages;

  /// No description provided for @invertVolumeKeys.
  ///
  /// In en, this message translates to:
  /// **'Invert volume keys'**
  String get invertVolumeKeys;

  /// No description provided for @brightness.
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get brightness;

  /// No description provided for @previousChapter.
  ///
  /// In en, this message translates to:
  /// **'Previous chapter'**
  String get previousChapter;

  /// No description provided for @thisTitle.
  ///
  /// In en, this message translates to:
  /// **'This title'**
  String get thisTitle;

  /// No description provided for @nextChapter2.
  ///
  /// In en, this message translates to:
  /// **'Next chapter →'**
  String get nextChapter2;

  /// No description provided for @textSize.
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get textSize;

  /// No description provided for @appliesStraightAway.
  ///
  /// In en, this message translates to:
  /// **'Applies straight away'**
  String get appliesStraightAway;

  /// No description provided for @left.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get left;

  /// No description provided for @justify.
  ///
  /// In en, this message translates to:
  /// **'Justify'**
  String get justify;

  /// No description provided for @ltr.
  ///
  /// In en, this message translates to:
  /// **'LTR'**
  String get ltr;

  /// No description provided for @rtl.
  ///
  /// In en, this message translates to:
  /// **'RTL'**
  String get rtl;

  /// No description provided for @letterSpacing.
  ///
  /// In en, this message translates to:
  /// **'Letter spacing'**
  String get letterSpacing;

  /// No description provided for @wordSpacing.
  ///
  /// In en, this message translates to:
  /// **'Word spacing'**
  String get wordSpacing;

  /// No description provided for @alignment.
  ///
  /// In en, this message translates to:
  /// **'Alignment'**
  String get alignment;

  /// No description provided for @a.
  ///
  /// In en, this message translates to:
  /// **'A'**
  String get a;

  /// No description provided for @searchEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Search episodes'**
  String get searchEpisodes;

  /// No description provided for @titleOrEpisodeNumber.
  ///
  /// In en, this message translates to:
  /// **'Title or episode number'**
  String get titleOrEpisodeNumber;

  /// No description provided for @failedToLoadThisTitle.
  ///
  /// In en, this message translates to:
  /// **'Failed to load this title'**
  String get failedToLoadThisTitle;

  /// No description provided for @changeStatus.
  ///
  /// In en, this message translates to:
  /// **'Change status'**
  String get changeStatus;

  /// No description provided for @tracking.
  ///
  /// In en, this message translates to:
  /// **'Tracking'**
  String get tracking;

  /// No description provided for @noEpisodesAvailableFromThisSource.
  ///
  /// In en, this message translates to:
  /// **'No episodes available from this source'**
  String get noEpisodesAvailableFromThisSource;

  /// No description provided for @noEpisodesMatchYourSearch.
  ///
  /// In en, this message translates to:
  /// **'No episodes match your search'**
  String get noEpisodesMatchYourSearch;

  /// No description provided for @everyChapterIsAlreadyDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Every chapter is already downloaded'**
  String get everyChapterIsAlreadyDownloaded;

  /// No description provided for @downloadChapters.
  ///
  /// In en, this message translates to:
  /// **'Download chapters'**
  String get downloadChapters;

  /// No description provided for @thisWillTakeAWhileAndUseALotOfStorage.
  ///
  /// In en, this message translates to:
  /// **'This will take a while and use a lot of storage'**
  String get thisWillTakeAWhileAndUseALotOfStorage;

  /// No description provided for @findEpisode.
  ///
  /// In en, this message translates to:
  /// **'Find episode'**
  String get findEpisode;

  /// No description provided for @refreshChapters.
  ///
  /// In en, this message translates to:
  /// **'Refresh chapters'**
  String get refreshChapters;

  /// No description provided for @refreshEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Refresh episodes'**
  String get refreshEpisodes;

  /// No description provided for @seasons.
  ///
  /// In en, this message translates to:
  /// **'Seasons'**
  String get seasons;

  /// No description provided for @goToEpisode.
  ///
  /// In en, this message translates to:
  /// **'Go to episode'**
  String get goToEpisode;

  /// No description provided for @episodeNumber.
  ///
  /// In en, this message translates to:
  /// **'Episode number'**
  String get episodeNumber;

  /// No description provided for @cancelDownload.
  ///
  /// In en, this message translates to:
  /// **'Cancel download'**
  String get cancelDownload;

  /// No description provided for @downloaded.
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get downloaded;

  /// No description provided for @downloadChapter.
  ///
  /// In en, this message translates to:
  /// **'Download chapter'**
  String get downloadChapter;

  /// No description provided for @deleteDownload.
  ///
  /// In en, this message translates to:
  /// **'Delete download'**
  String get deleteDownload;

  /// No description provided for @resumeDownload.
  ///
  /// In en, this message translates to:
  /// **'Resume download'**
  String get resumeDownload;

  /// No description provided for @status.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get status;

  /// No description provided for @year.
  ///
  /// In en, this message translates to:
  /// **'Year'**
  String get year;

  /// No description provided for @studio.
  ///
  /// In en, this message translates to:
  /// **'Studio'**
  String get studio;

  /// No description provided for @genres.
  ///
  /// In en, this message translates to:
  /// **'Genres'**
  String get genres;

  /// No description provided for @synopsis.
  ///
  /// In en, this message translates to:
  /// **'Synopsis'**
  String get synopsis;

  /// No description provided for @readMore.
  ///
  /// In en, this message translates to:
  /// **'Read more'**
  String get readMore;

  /// No description provided for @downloadChooseServer.
  ///
  /// In en, this message translates to:
  /// **'Download · choose server'**
  String get downloadChooseServer;

  /// No description provided for @noDownloadSourcesFound.
  ///
  /// In en, this message translates to:
  /// **'No download sources found'**
  String get noDownloadSourcesFound;

  /// No description provided for @audio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get audio;

  /// No description provided for @noEpisodesMatch.
  ///
  /// In en, this message translates to:
  /// **'No episodes match'**
  String get noEpisodesMatch;

  /// No description provided for @selectEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Select episodes'**
  String get selectEpisodes;

  /// No description provided for @startFrom.
  ///
  /// In en, this message translates to:
  /// **'Start from'**
  String get startFrom;

  /// No description provided for @jumpToEpisode2.
  ///
  /// In en, this message translates to:
  /// **'Jump to episode'**
  String get jumpToEpisode2;

  /// No description provided for @downloadEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Download episodes'**
  String get downloadEpisodes;

  /// No description provided for @noEpisodes.
  ///
  /// In en, this message translates to:
  /// **'No episodes'**
  String get noEpisodes;

  /// No description provided for @dub2.
  ///
  /// In en, this message translates to:
  /// **'dub'**
  String get dub2;

  /// No description provided for @autoBestAvailable.
  ///
  /// In en, this message translates to:
  /// **'Auto · best available'**
  String get autoBestAvailable;

  /// No description provided for @linksReloaded.
  ///
  /// In en, this message translates to:
  /// **'Links reloaded'**
  String get linksReloaded;

  /// No description provided for @noSourcesFoundForThisEpisode.
  ///
  /// In en, this message translates to:
  /// **'No sources found for this episode'**
  String get noSourcesFoundForThisEpisode;

  /// No description provided for @starring.
  ///
  /// In en, this message translates to:
  /// **'Starring'**
  String get starring;

  /// No description provided for @creators.
  ///
  /// In en, this message translates to:
  /// **'Creators'**
  String get creators;

  /// No description provided for @notify.
  ///
  /// In en, this message translates to:
  /// **'Notify'**
  String get notify;

  /// No description provided for @stopAlerts.
  ///
  /// In en, this message translates to:
  /// **'Stop alerts'**
  String get stopAlerts;

  /// No description provided for @trackedEditStatusScoreProgress.
  ///
  /// In en, this message translates to:
  /// **'Tracked — edit status, score & progress'**
  String get trackedEditStatusScoreProgress;

  /// No description provided for @openSourceSite.
  ///
  /// In en, this message translates to:
  /// **'Open source site'**
  String get openSourceSite;

  /// No description provided for @welcomeBack.
  ///
  /// In en, this message translates to:
  /// **'Welcome back'**
  String get welcomeBack;

  /// No description provided for @signInToSyncYourListAcrossDevices.
  ///
  /// In en, this message translates to:
  /// **'Sign in to sync your list across devices.'**
  String get signInToSyncYourListAcrossDevices;

  /// No description provided for @logIn.
  ///
  /// In en, this message translates to:
  /// **'Log in'**
  String get logIn;

  /// No description provided for @passwordMustBeAtLeast8Characters.
  ///
  /// In en, this message translates to:
  /// **'Password must be at least 8 characters'**
  String get passwordMustBeAtLeast8Characters;

  /// No description provided for @createAccount.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get createAccount;

  /// No description provided for @saveYourListAndContinueWatchingAnywhere.
  ///
  /// In en, this message translates to:
  /// **'Save your list and continue watching anywhere.'**
  String get saveYourListAndContinueWatchingAnywhere;

  /// No description provided for @notSignedIn.
  ///
  /// In en, this message translates to:
  /// **'Not signed in'**
  String get notSignedIn;

  /// No description provided for @haveTheApp.
  ///
  /// In en, this message translates to:
  /// **'Have the app?'**
  String get haveTheApp;

  /// No description provided for @openZangetsuOnYourNphoneAndScan.
  ///
  /// In en, this message translates to:
  /// **'Open Zangetsu on your\\nphone and scan'**
  String get openZangetsuOnYourNphoneAndScan;

  /// No description provided for @noApp.
  ///
  /// In en, this message translates to:
  /// **'No app?'**
  String get noApp;

  /// No description provided for @resetPassword.
  ///
  /// In en, this message translates to:
  /// **'Reset password'**
  String get resetPassword;

  /// No description provided for @youExampleCom.
  ///
  /// In en, this message translates to:
  /// **'you@example.com'**
  String get youExampleCom;

  /// No description provided for @sendLink.
  ///
  /// In en, this message translates to:
  /// **'Send link'**
  String get sendLink;

  /// No description provided for @email.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get email;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @forgotPassword.
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get forgotPassword;

  /// No description provided for @name.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get name;

  /// No description provided for @password8Characters.
  ///
  /// In en, this message translates to:
  /// **'Password (8+ characters)'**
  String get password8Characters;

  /// No description provided for @editName.
  ///
  /// In en, this message translates to:
  /// **'Edit name'**
  String get editName;

  /// No description provided for @yourName.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get yourName;

  /// No description provided for @couldnTUpdateYourName.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t update your name'**
  String get couldnTUpdateYourName;

  /// No description provided for @pairATV.
  ///
  /// In en, this message translates to:
  /// **'Pair a TV'**
  String get pairATV;

  /// No description provided for @addPhoto.
  ///
  /// In en, this message translates to:
  /// **'Add photo'**
  String get addPhoto;

  /// No description provided for @backUpBeforeLoggingOut.
  ///
  /// In en, this message translates to:
  /// **'Back up before logging out?'**
  String get backUpBeforeLoggingOut;

  /// No description provided for @logOutAnyway.
  ///
  /// In en, this message translates to:
  /// **'Log out anyway'**
  String get logOutAnyway;

  /// No description provided for @reconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get reconnect;

  /// No description provided for @signInWithYourPhone.
  ///
  /// In en, this message translates to:
  /// **'Sign in with your phone'**
  String get signInWithYourPhone;

  /// No description provided for @onTheZangetsuAppOnYourPhoneOpenNPairATVAndEnterThisCodeOrScanTheQR.
  ///
  /// In en, this message translates to:
  /// **'On the Zangetsu app on your phone, open\\n\"Pair a TV\" and enter this code — or scan the QR.'**
  String get onTheZangetsuAppOnYourPhoneOpenNPairATVAndEnterThisCodeOrScanTheQR;

  /// No description provided for @signingIn.
  ///
  /// In en, this message translates to:
  /// **'Signing in…'**
  String get signingIn;

  /// No description provided for @getANewCode.
  ///
  /// In en, this message translates to:
  /// **'Get a new code'**
  String get getANewCode;

  /// No description provided for @sendTrackers.
  ///
  /// In en, this message translates to:
  /// **'Send trackers'**
  String get sendTrackers;

  /// No description provided for @chooseTrackersToSend.
  ///
  /// In en, this message translates to:
  /// **'Choose trackers to send'**
  String get chooseTrackersToSend;

  /// No description provided for @sendToTV.
  ///
  /// In en, this message translates to:
  /// **'Send to TV'**
  String get sendToTV;

  /// No description provided for @signInToYourAccountFirstNthenPairYourTV.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your account first,\\nthen pair your TV.'**
  String get signInToYourAccountFirstNthenPairYourTV;

  /// No description provided for @enterTheCodeFromYourTV.
  ///
  /// In en, this message translates to:
  /// **'Enter the code from your TV'**
  String get enterTheCodeFromYourTV;

  /// No description provided for @openZangetsuOnYourTVAndSignInWithYourPhoneToSeeIt.
  ///
  /// In en, this message translates to:
  /// **'Open Zangetsu on your TV and sign in with your phone to see it.'**
  String get openZangetsuOnYourTVAndSignInWithYourPhoneToSeeIt;

  /// No description provided for @abcd2345.
  ///
  /// In en, this message translates to:
  /// **'ABCD 2345'**
  String get abcd2345;

  /// No description provided for @thisTVWillSignIntoYourAccountYouCanSignItOutLater.
  ///
  /// In en, this message translates to:
  /// **'This TV will sign into your account. You can sign it out later.'**
  String get thisTVWillSignIntoYourAccountYouCanSignItOutLater;

  /// No description provided for @alsoSendYourTrackersAniListMyAnimeListSimkl.
  ///
  /// In en, this message translates to:
  /// **'Also send your trackers (AniList, MyAnimeList, Simkl)'**
  String get alsoSendYourTrackersAniListMyAnimeListSimkl;

  /// No description provided for @yourTVIsSignedIn.
  ///
  /// In en, this message translates to:
  /// **'Your TV is signed in'**
  String get yourTVIsSignedIn;

  /// No description provided for @itShouldSwitchToYourAccountInAMoment.
  ///
  /// In en, this message translates to:
  /// **'It should switch to your account in a moment.'**
  String get itShouldSwitchToYourAccountInAMoment;

  /// No description provided for @backedUpToCloud.
  ///
  /// In en, this message translates to:
  /// **'Backed up to cloud'**
  String get backedUpToCloud;

  /// No description provided for @couldnTSaveTheBackupFileStoragePermissionMayBeNeeded.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the backup file — storage permission may be needed.'**
  String get couldnTSaveTheBackupFileStoragePermissionMayBeNeeded;

  /// No description provided for @noCloudBackupFound.
  ///
  /// In en, this message translates to:
  /// **'No cloud backup found'**
  String get noCloudBackupFound;

  /// No description provided for @thatFileIsnTAValidBackup.
  ///
  /// In en, this message translates to:
  /// **'That file isn\'t a valid backup.'**
  String get thatFileIsnTAValidBackup;

  /// No description provided for @pickABackup.
  ///
  /// In en, this message translates to:
  /// **'Pick a backup'**
  String get pickABackup;

  /// No description provided for @couldnTReadThatBackupFile.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read that backup file.'**
  String get couldnTReadThatBackupFile;

  /// No description provided for @restoreComplete.
  ///
  /// In en, this message translates to:
  /// **'Restore complete'**
  String get restoreComplete;

  /// No description provided for @reopenZangetsuToSeeRestoredLibrarySources.
  ///
  /// In en, this message translates to:
  /// **'Reopen Zangetsu to see restored library & sources.'**
  String get reopenZangetsuToSeeRestoredLibrarySources;

  /// No description provided for @saveToAFile.
  ///
  /// In en, this message translates to:
  /// **'Save to a file'**
  String get saveToAFile;

  /// No description provided for @saveABackupFileToYourDownloadsFolder.
  ///
  /// In en, this message translates to:
  /// **'Save a backup file to your Downloads folder'**
  String get saveABackupFileToYourDownloadsFolder;

  /// No description provided for @backUpToCloud.
  ///
  /// In en, this message translates to:
  /// **'Back up to cloud'**
  String get backUpToCloud;

  /// No description provided for @saveACopyToYourAccountNeedsSignIn.
  ///
  /// In en, this message translates to:
  /// **'Save a copy to your account · needs sign-in'**
  String get saveACopyToYourAccountNeedsSignIn;

  /// No description provided for @restoreFromAFile.
  ///
  /// In en, this message translates to:
  /// **'Restore from a file'**
  String get restoreFromAFile;

  /// No description provided for @pickABackupFileYouSavedEarlier.
  ///
  /// In en, this message translates to:
  /// **'Pick a backup file you saved earlier'**
  String get pickABackupFileYouSavedEarlier;

  /// No description provided for @restoreFromCloud.
  ///
  /// In en, this message translates to:
  /// **'Restore from cloud'**
  String get restoreFromCloud;

  /// No description provided for @bringBackYourLatestCloudBackup.
  ///
  /// In en, this message translates to:
  /// **'Bring back your latest cloud backup'**
  String get bringBackYourLatestCloudBackup;

  /// No description provided for @episodesYouDownloadAppearHere.
  ///
  /// In en, this message translates to:
  /// **'Episodes you download appear here'**
  String get episodesYouDownloadAppearHere;

  /// No description provided for @deleteAllEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Delete all episodes'**
  String get deleteAllEpisodes;

  /// No description provided for @deleteAllDownloads.
  ///
  /// In en, this message translates to:
  /// **'Delete all downloads?'**
  String get deleteAllDownloads;

  /// No description provided for @deleteAll.
  ///
  /// In en, this message translates to:
  /// **'Delete all'**
  String get deleteAll;

  /// No description provided for @changeDownloadFolder.
  ///
  /// In en, this message translates to:
  /// **'Change download folder'**
  String get changeDownloadFolder;

  /// No description provided for @savingTo.
  ///
  /// In en, this message translates to:
  /// **'Saving to'**
  String get savingTo;

  /// No description provided for @needsAFileManagerAppOnTheTV.
  ///
  /// In en, this message translates to:
  /// **'Needs a file-manager app on the TV'**
  String get needsAFileManagerAppOnTheTV;

  /// No description provided for @downloadLocation.
  ///
  /// In en, this message translates to:
  /// **'Download location'**
  String get downloadLocation;

  /// No description provided for @novelChaptersYouDownloadAppearHere.
  ///
  /// In en, this message translates to:
  /// **'Novel chapters you download appear here'**
  String get novelChaptersYouDownloadAppearHere;

  /// No description provided for @stopDownloading.
  ///
  /// In en, this message translates to:
  /// **'Stop downloading?'**
  String get stopDownloading;

  /// No description provided for @keepGoing.
  ///
  /// In en, this message translates to:
  /// **'Keep going'**
  String get keepGoing;

  /// No description provided for @stopAll.
  ///
  /// In en, this message translates to:
  /// **'Stop all'**
  String get stopAll;

  /// No description provided for @searchDownloads.
  ///
  /// In en, this message translates to:
  /// **'Search downloads'**
  String get searchDownloads;

  /// No description provided for @deleteAllChapters.
  ///
  /// In en, this message translates to:
  /// **'Delete all chapters'**
  String get deleteAllChapters;

  /// No description provided for @deleteAllChapters2.
  ///
  /// In en, this message translates to:
  /// **'Delete all chapters?'**
  String get deleteAllChapters2;

  /// No description provided for @chapter.
  ///
  /// In en, this message translates to:
  /// **'Chapter'**
  String get chapter;

  /// No description provided for @downloadSettings.
  ///
  /// In en, this message translates to:
  /// **'Download settings'**
  String get downloadSettings;

  /// No description provided for @parallelDownloads.
  ///
  /// In en, this message translates to:
  /// **'Parallel downloads'**
  String get parallelDownloads;

  /// No description provided for @connectionsPerDownload.
  ///
  /// In en, this message translates to:
  /// **'Connections per download'**
  String get connectionsPerDownload;

  /// No description provided for @novels.
  ///
  /// In en, this message translates to:
  /// **'Novels'**
  String get novels;

  /// No description provided for @noDownloadsMatchYourSearch.
  ///
  /// In en, this message translates to:
  /// **'No downloads match your search'**
  String get noDownloadsMatchYourSearch;

  /// No description provided for @collapseAll.
  ///
  /// In en, this message translates to:
  /// **'Collapse all'**
  String get collapseAll;

  /// No description provided for @requestedControl.
  ///
  /// In en, this message translates to:
  /// **'Requested control'**
  String get requestedControl;

  /// No description provided for @noParticipantsYet.
  ///
  /// In en, this message translates to:
  /// **'No participants yet'**
  String get noParticipantsYet;

  /// No description provided for @guest.
  ///
  /// In en, this message translates to:
  /// **'Guest'**
  String get guest;

  /// No description provided for @wantsControl.
  ///
  /// In en, this message translates to:
  /// **'Wants control'**
  String get wantsControl;

  /// No description provided for @giveControl.
  ///
  /// In en, this message translates to:
  /// **'Give control'**
  String get giveControl;

  /// No description provided for @hostControlsPlayback.
  ///
  /// In en, this message translates to:
  /// **'Host controls playback'**
  String get hostControlsPlayback;

  /// No description provided for @requestControl.
  ///
  /// In en, this message translates to:
  /// **'Request control'**
  String get requestControl;

  /// No description provided for @inviteCopied.
  ///
  /// In en, this message translates to:
  /// **'Invite copied'**
  String get inviteCopied;

  /// No description provided for @roomChat.
  ///
  /// In en, this message translates to:
  /// **'Room Chat'**
  String get roomChat;

  /// No description provided for @noMessagesYet.
  ///
  /// In en, this message translates to:
  /// **'No messages yet'**
  String get noMessagesYet;

  /// No description provided for @message.
  ///
  /// In en, this message translates to:
  /// **'Message…'**
  String get message;

  /// No description provided for @invite.
  ///
  /// In en, this message translates to:
  /// **'Invite'**
  String get invite;

  /// No description provided for @watchTogether.
  ///
  /// In en, this message translates to:
  /// **'Watch Together'**
  String get watchTogether;

  /// No description provided for @createARoom.
  ///
  /// In en, this message translates to:
  /// **'Create a room'**
  String get createARoom;

  /// No description provided for @joinWithACode.
  ///
  /// In en, this message translates to:
  /// **'Join with a code'**
  String get joinWithACode;

  /// No description provided for @roomNotFound.
  ///
  /// In en, this message translates to:
  /// **'Room not found'**
  String get roomNotFound;

  /// No description provided for @enterRoomCode.
  ///
  /// In en, this message translates to:
  /// **'Enter room code'**
  String get enterRoomCode;

  /// No description provided for @eGABC234.
  ///
  /// In en, this message translates to:
  /// **'e.g. ABC234'**
  String get eGABC234;

  /// No description provided for @hostIsChoosing.
  ///
  /// In en, this message translates to:
  /// **'Host is choosing…'**
  String get hostIsChoosing;

  /// No description provided for @youLlStartWatchingAutomaticallyWhenTheHostPlaysSomething.
  ///
  /// In en, this message translates to:
  /// **'You\'ll start watching automatically when the host plays something.'**
  String get youLlStartWatchingAutomaticallyWhenTheHostPlaysSomething;

  /// No description provided for @participants.
  ///
  /// In en, this message translates to:
  /// **'Participants'**
  String get participants;

  /// No description provided for @signInToUseWatchParty.
  ///
  /// In en, this message translates to:
  /// **'Sign in to use Watch Party'**
  String get signInToUseWatchParty;

  /// No description provided for @youReAlreadyInAParty.
  ///
  /// In en, this message translates to:
  /// **'You\'re already in a party'**
  String get youReAlreadyInAParty;

  /// No description provided for @watchTogether2.
  ///
  /// In en, this message translates to:
  /// **'Watch together'**
  String get watchTogether2;

  /// No description provided for @createAPartyAndInviteFriendsOrJoinAnExistingOneWithACode.
  ///
  /// In en, this message translates to:
  /// **'Create a party and invite friends, or join an existing one with a code.'**
  String get createAPartyAndInviteFriendsOrJoinAnExistingOneWithACode;

  /// No description provided for @aniyomiIsnTAvailableOnThisDevice.
  ///
  /// In en, this message translates to:
  /// **'Aniyomi isn\'t available on this device.'**
  String get aniyomiIsnTAvailableOnThisDevice;

  /// No description provided for @installed.
  ///
  /// In en, this message translates to:
  /// **'Installed'**
  String get installed;

  /// No description provided for @repositories.
  ///
  /// In en, this message translates to:
  /// **'Repositories'**
  String get repositories;

  /// No description provided for @languages.
  ///
  /// In en, this message translates to:
  /// **'Languages'**
  String get languages;

  /// No description provided for @addAniyomiRepo.
  ///
  /// In en, this message translates to:
  /// **'Add Aniyomi repo'**
  String get addAniyomiRepo;

  /// No description provided for @noAniyomiSourcesInstalled.
  ///
  /// In en, this message translates to:
  /// **'No Aniyomi sources installed.'**
  String get noAniyomiSourcesInstalled;

  /// No description provided for @removeRepo.
  ///
  /// In en, this message translates to:
  /// **'Remove repo?'**
  String get removeRepo;

  /// No description provided for @noAniyomiReposAddedYetNPressAddAniyomiRepoToAddOne.
  ///
  /// In en, this message translates to:
  /// **'No Aniyomi repos added yet.\\nPress \"Add Aniyomi repo\" to add one.'**
  String get noAniyomiReposAddedYetNPressAddAniyomiRepoToAddOne;

  /// No description provided for @addRepository.
  ///
  /// In en, this message translates to:
  /// **'Add repository'**
  String get addRepository;

  /// No description provided for @searchNovelSources.
  ///
  /// In en, this message translates to:
  /// **'Search novel sources'**
  String get searchNovelSources;

  /// No description provided for @noSourcesInstalledYet.
  ///
  /// In en, this message translates to:
  /// **'No sources installed yet.'**
  String get noSourcesInstalledYet;

  /// No description provided for @addNovelRepo.
  ///
  /// In en, this message translates to:
  /// **'Add novel repo'**
  String get addNovelRepo;

  /// No description provided for @removeRepository.
  ///
  /// In en, this message translates to:
  /// **'Remove repository'**
  String get removeRepository;

  /// No description provided for @noSourcesInThisRepo.
  ///
  /// In en, this message translates to:
  /// **'No sources in this repo.'**
  String get noSourcesInThisRepo;

  /// No description provided for @zangetsuProviders.
  ///
  /// In en, this message translates to:
  /// **'Zangetsu providers'**
  String get zangetsuProviders;

  /// No description provided for @addRepo.
  ///
  /// In en, this message translates to:
  /// **'Add repo'**
  String get addRepo;

  /// No description provided for @noProvidersInstalled.
  ///
  /// In en, this message translates to:
  /// **'No providers installed.'**
  String get noProvidersInstalled;

  /// No description provided for @noSourcesInThisRepoYet.
  ///
  /// In en, this message translates to:
  /// **'No sources in this repo yet.'**
  String get noSourcesInThisRepoYet;

  /// No description provided for @leaveBlankToUseTheRepoSOwnName.
  ///
  /// In en, this message translates to:
  /// **'Leave blank to use the repo\'s own name'**
  String get leaveBlankToUseTheRepoSOwnName;

  /// No description provided for @addCloudStreamRepo.
  ///
  /// In en, this message translates to:
  /// **'Add CloudStream repo'**
  String get addCloudStreamRepo;

  /// No description provided for @noCloudStreamSourcesInstalled.
  ///
  /// In en, this message translates to:
  /// **'No CloudStream sources installed.'**
  String get noCloudStreamSourcesInstalled;

  /// No description provided for @cloudstream.
  ///
  /// In en, this message translates to:
  /// **'cloudstream'**
  String get cloudstream;

  /// No description provided for @sourceSettings.
  ///
  /// In en, this message translates to:
  /// **'Source settings'**
  String get sourceSettings;

  /// No description provided for @removeRepository2.
  ///
  /// In en, this message translates to:
  /// **'Remove repository?'**
  String get removeRepository2;

  /// No description provided for @removeThisRepositoryAndItsSources.
  ///
  /// In en, this message translates to:
  /// **'Remove this repository and its sources?'**
  String get removeThisRepositoryAndItsSources;

  /// No description provided for @removed.
  ///
  /// In en, this message translates to:
  /// **'Removed'**
  String get removed;

  /// No description provided for @alreadyUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Already up to date'**
  String get alreadyUpToDate;

  /// No description provided for @removeRepo2.
  ///
  /// In en, this message translates to:
  /// **'Remove repo'**
  String get removeRepo2;

  /// No description provided for @noInstallableSourcesFoundInThisRepo.
  ///
  /// In en, this message translates to:
  /// **'No installable sources found in this repo.'**
  String get noInstallableSourcesFoundInThisRepo;

  /// No description provided for @thisRemovesTheSourceFromYourInstalledList.
  ///
  /// In en, this message translates to:
  /// **'This removes the source from your installed list.'**
  String get thisRemovesTheSourceFromYourInstalledList;

  /// No description provided for @addCSRepo.
  ///
  /// In en, this message translates to:
  /// **'Add CS repo'**
  String get addCSRepo;

  /// No description provided for @cloudstreamIsnTAvailableOnThisDevice.
  ///
  /// In en, this message translates to:
  /// **'CloudStream isn\'t available on this device.'**
  String get cloudstreamIsnTAvailableOnThisDevice;

  /// No description provided for @checkUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check updates'**
  String get checkUpdates;

  /// No description provided for @pasteACloudStreamRepositoryURL.
  ///
  /// In en, this message translates to:
  /// **'Paste a CloudStream repository URL.'**
  String get pasteACloudStreamRepositoryURL;

  /// No description provided for @reTest.
  ///
  /// In en, this message translates to:
  /// **'Re-test'**
  String get reTest;

  /// No description provided for @noEnabledSourcesToTest.
  ///
  /// In en, this message translates to:
  /// **'No enabled sources to test.'**
  String get noEnabledSourcesToTest;

  /// No description provided for @notSearched.
  ///
  /// In en, this message translates to:
  /// **'Not searched'**
  String get notSearched;

  /// No description provided for @thisSourceHasNoSettings.
  ///
  /// In en, this message translates to:
  /// **'This source has no settings'**
  String get thisSourceHasNoSettings;

  /// No description provided for @resetToDefaults.
  ///
  /// In en, this message translates to:
  /// **'Reset to defaults'**
  String get resetToDefaults;

  /// No description provided for @providerSettings.
  ///
  /// In en, this message translates to:
  /// **'Provider settings'**
  String get providerSettings;

  /// No description provided for @openThisSourceSOwnSettingsEGServerLanguage.
  ///
  /// In en, this message translates to:
  /// **'Open this source\'s own settings (e.g. server, language)'**
  String get openThisSourceSOwnSettingsEGServerLanguage;

  /// No description provided for @addZangetsuRepo.
  ///
  /// In en, this message translates to:
  /// **'Add Zangetsu repo'**
  String get addZangetsuRepo;

  /// No description provided for @theProviderWillBeRemovedFromYourInstalledSources.
  ///
  /// In en, this message translates to:
  /// **'The provider will be removed from your installed sources.'**
  String get theProviderWillBeRemovedFromYourInstalledSources;

  /// No description provided for @addMihonRepo.
  ///
  /// In en, this message translates to:
  /// **'Add Mihon repo'**
  String get addMihonRepo;

  /// No description provided for @noMihonReposAddedYetNTapAddMihonRepoToAddOne.
  ///
  /// In en, this message translates to:
  /// **'No Mihon repos added yet.\\nTap \"Add Mihon repo\" to add one.'**
  String get noMihonReposAddedYetNTapAddMihonRepoToAddOne;

  /// No description provided for @n1Update.
  ///
  /// In en, this message translates to:
  /// **'1 update'**
  String get n1Update;

  /// No description provided for @noExtensionsFoundInThisRepo.
  ///
  /// In en, this message translates to:
  /// **'No extensions found in this repo.'**
  String get noExtensionsFoundInThisRepo;

  /// No description provided for @thisRemovesTheExtensionFromYourInstalledSources.
  ///
  /// In en, this message translates to:
  /// **'This removes the extension from your installed sources.'**
  String get thisRemovesTheExtensionFromYourInstalledSources;

  /// No description provided for @noMihonSourcesInstalled.
  ///
  /// In en, this message translates to:
  /// **'No Mihon sources installed.'**
  String get noMihonSourcesInstalled;

  /// No description provided for @noAniyomiReposAddedYetNTapAddAniyomiRepoToAddOne.
  ///
  /// In en, this message translates to:
  /// **'No Aniyomi repos added yet.\\nTap \"Add Aniyomi repo\" to add one.'**
  String get noAniyomiReposAddedYetNTapAddAniyomiRepoToAddOne;

  /// No description provided for @clearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear all'**
  String get clearAll;

  /// No description provided for @nothingWatchedYet.
  ///
  /// In en, this message translates to:
  /// **'Nothing watched yet'**
  String get nothingWatchedYet;

  /// No description provided for @nothingReadYet.
  ///
  /// In en, this message translates to:
  /// **'Nothing read yet'**
  String get nothingReadYet;

  /// No description provided for @checkingForNewEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Checking for new episodes…'**
  String get checkingForNewEpisodes;

  /// No description provided for @checkNow.
  ///
  /// In en, this message translates to:
  /// **'Check now'**
  String get checkNow;

  /// No description provided for @turnOff.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get turnOff;

  /// No description provided for @joinBetaUpdates.
  ///
  /// In en, this message translates to:
  /// **'Join beta updates?'**
  String get joinBetaUpdates;

  /// No description provided for @joinBeta.
  ///
  /// In en, this message translates to:
  /// **'Join beta'**
  String get joinBeta;

  /// No description provided for @whatSNew.
  ///
  /// In en, this message translates to:
  /// **'What\'s new'**
  String get whatSNew;

  /// No description provided for @categories.
  ///
  /// In en, this message translates to:
  /// **'Categories'**
  String get categories;

  /// No description provided for @moviesSeries2.
  ///
  /// In en, this message translates to:
  /// **'Movies/Series'**
  String get moviesSeries2;

  /// No description provided for @longPressASourceToPinItToTheTop.
  ///
  /// In en, this message translates to:
  /// **'Long-press a source to pin it to the top'**
  String get longPressASourceToPinItToTheTop;

  /// No description provided for @searchSources.
  ///
  /// In en, this message translates to:
  /// **'Search sources'**
  String get searchSources;

  /// No description provided for @justLook.
  ///
  /// In en, this message translates to:
  /// **'Just look'**
  String get justLook;

  /// No description provided for @moveProgressHere.
  ///
  /// In en, this message translates to:
  /// **'Move progress here'**
  String get moveProgressHere;

  /// No description provided for @newAniListList.
  ///
  /// In en, this message translates to:
  /// **'New AniList list'**
  String get newAniListList;

  /// No description provided for @rewatchingFavourites.
  ///
  /// In en, this message translates to:
  /// **'Rewatching, Favourites, …'**
  String get rewatchingFavourites;

  /// No description provided for @anilistCustomLists.
  ///
  /// In en, this message translates to:
  /// **'AniList custom lists'**
  String get anilistCustomLists;

  /// No description provided for @savedToYourAniListAccount.
  ///
  /// In en, this message translates to:
  /// **'Saved to your AniList account'**
  String get savedToYourAniListAccount;

  /// No description provided for @newList.
  ///
  /// In en, this message translates to:
  /// **'New list'**
  String get newList;

  /// No description provided for @createsItOnAniList.
  ///
  /// In en, this message translates to:
  /// **'Creates it on AniList'**
  String get createsItOnAniList;

  /// No description provided for @yourTrackersDisagree.
  ///
  /// In en, this message translates to:
  /// **'Your trackers disagree'**
  String get yourTrackersDisagree;

  /// No description provided for @applyingSetsThemAllToTheNumberBelow.
  ///
  /// In en, this message translates to:
  /// **'Applying sets them all to the number below.'**
  String get applyingSetsThemAllToTheNumberBelow;

  /// No description provided for @wrongTitleChangeMatch.
  ///
  /// In en, this message translates to:
  /// **'Wrong title?  Change match'**
  String get wrongTitleChangeMatch;

  /// No description provided for @searchTheCorrectTitle.
  ///
  /// In en, this message translates to:
  /// **'Search the correct title…'**
  String get searchTheCorrectTitle;

  /// No description provided for @noMatchesFound.
  ///
  /// In en, this message translates to:
  /// **'No matches found'**
  String get noMatchesFound;

  /// No description provided for @removeFromMyList.
  ///
  /// In en, this message translates to:
  /// **'Remove from My List'**
  String get removeFromMyList;

  /// No description provided for @details.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get details;

  /// No description provided for @noDescriptionAvailable.
  ///
  /// In en, this message translates to:
  /// **'No description available.'**
  String get noDescriptionAvailable;

  /// No description provided for @playWith.
  ///
  /// In en, this message translates to:
  /// **'Play with…'**
  String get playWith;

  /// No description provided for @playMirror.
  ///
  /// In en, this message translates to:
  /// **'Play mirror'**
  String get playMirror;

  /// No description provided for @chooseTheSourceBeforeItStarts.
  ///
  /// In en, this message translates to:
  /// **'Choose the source before it starts'**
  String get chooseTheSourceBeforeItStarts;

  /// No description provided for @reloadLinks.
  ///
  /// In en, this message translates to:
  /// **'Reload links'**
  String get reloadLinks;

  /// No description provided for @fetchFreshStreamsIfPlaybackKeepsFailing.
  ///
  /// In en, this message translates to:
  /// **'Fetch fresh streams if playback keeps failing'**
  String get fetchFreshStreamsIfPlaybackKeepsFailing;

  /// No description provided for @alsoUpdatesYourConnectedTrackers.
  ///
  /// In en, this message translates to:
  /// **'Also updates your connected trackers'**
  String get alsoUpdatesYourConnectedTrackers;

  /// No description provided for @markThisAndAllAboveAsWatched.
  ///
  /// In en, this message translates to:
  /// **'Mark this and all above as watched'**
  String get markThisAndAllAboveAsWatched;

  /// No description provided for @playThisEpisodeWith.
  ///
  /// In en, this message translates to:
  /// **'Play this episode with'**
  String get playThisEpisodeWith;

  /// No description provided for @builtInPlayer.
  ///
  /// In en, this message translates to:
  /// **'Built-in player'**
  String get builtInPlayer;

  /// No description provided for @otherApps.
  ///
  /// In en, this message translates to:
  /// **'Other apps'**
  String get otherApps;

  /// No description provided for @seeAll2.
  ///
  /// In en, this message translates to:
  /// **'See All'**
  String get seeAll2;

  /// No description provided for @openInBrowser.
  ///
  /// In en, this message translates to:
  /// **'Open in browser'**
  String get openInBrowser;

  /// No description provided for @copyLink.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get copyLink;

  /// No description provided for @removeTracking.
  ///
  /// In en, this message translates to:
  /// **'Remove tracking'**
  String get removeTracking;

  /// No description provided for @noTrackersConnectedNConnectOneInSettingsConnections.
  ///
  /// In en, this message translates to:
  /// **'No trackers connected.\\nConnect one in Settings → Connections.'**
  String get noTrackersConnectedNConnectOneInSettingsConnections;

  /// No description provided for @syncAllAtOnce.
  ///
  /// In en, this message translates to:
  /// **'Sync all at once'**
  String get syncAllAtOnce;

  /// No description provided for @addTracking.
  ///
  /// In en, this message translates to:
  /// **'Add tracking'**
  String get addTracking;

  /// No description provided for @addToYourList.
  ///
  /// In en, this message translates to:
  /// **'Add to your list'**
  String get addToYourList;

  /// No description provided for @removeFromList.
  ///
  /// In en, this message translates to:
  /// **'Remove from list'**
  String get removeFromList;

  /// No description provided for @customLists.
  ///
  /// In en, this message translates to:
  /// **'Custom lists'**
  String get customLists;

  /// No description provided for @notInAny.
  ///
  /// In en, this message translates to:
  /// **'Not in any'**
  String get notInAny;

  /// No description provided for @status2.
  ///
  /// In en, this message translates to:
  /// **'STATUS'**
  String get status2;

  /// No description provided for @applyChanges.
  ///
  /// In en, this message translates to:
  /// **'Apply changes'**
  String get applyChanges;

  /// No description provided for @navigationBar.
  ///
  /// In en, this message translates to:
  /// **'Navigation bar'**
  String get navigationBar;

  /// No description provided for @navigationBarSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Which tabs show, and their order'**
  String get navigationBarSubtitle;

  /// No description provided for @connectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} connected'**
  String connectedCount(int count);

  /// No description provided for @syncLibraryAlreadySynced.
  ///
  /// In en, this message translates to:
  /// **'Your library is already synced to this account.'**
  String get syncLibraryAlreadySynced;

  /// No description provided for @syncLibraryPushed.
  ///
  /// In en, this message translates to:
  /// **'Synced {history} history + {list} list items to your account.'**
  String syncLibraryPushed(int history, int list);

  /// No description provided for @navTabsOnBar.
  ///
  /// In en, this message translates to:
  /// **'On the bar · {count}/{max}'**
  String navTabsOnBar(int count, int max);

  /// No description provided for @navTabsNotShown.
  ///
  /// In en, this message translates to:
  /// **'Not shown'**
  String get navTabsNotShown;

  /// No description provided for @navTabsEveryTabOnBar.
  ///
  /// In en, this message translates to:
  /// **'Every tab is on the bar.'**
  String get navTabsEveryTabOnBar;

  /// No description provided for @navTabsHelp.
  ///
  /// In en, this message translates to:
  /// **'Drag to reorder. {minTabs}–{maxTabs} tabs fit on the bar.\n\nProfile is pinned because it is the only way into Settings — hiding it would leave no way back to this screen. Schedule only appears in Streaming mode; there is no airing schedule to show while you are reading.'**
  String navTabsHelp(int minTabs, int maxTabs);

  /// No description provided for @navTabsStreamingOnly.
  ///
  /// In en, this message translates to:
  /// **'Streaming only'**
  String get navTabsStreamingOnly;

  /// No description provided for @navTabsRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get navTabsRemove;

  /// No description provided for @navTabsKeepMinTabs.
  ///
  /// In en, this message translates to:
  /// **'Keep at least {min} tabs'**
  String navTabsKeepMinTabs(int min);

  /// No description provided for @navTabsAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get navTabsAdd;

  /// No description provided for @navTabsBarFull.
  ///
  /// In en, this message translates to:
  /// **'The bar is full'**
  String get navTabsBarFull;

  /// No description provided for @filterShowResults.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Show # result} other{Show # results}}'**
  String filterShowResults(int count);

  /// No description provided for @addedCloudStreamSourcesCount.
  ///
  /// In en, this message translates to:
  /// **'Added — {count} CloudStream source(s) available'**
  String addedCloudStreamSourcesCount(int count);

  /// No description provided for @failedToAddRepository.
  ///
  /// In en, this message translates to:
  /// **'Failed to add repository: {error}'**
  String failedToAddRepository(String error);

  /// No description provided for @repositoryUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Repository URL'**
  String get repositoryUrlLabel;

  /// No description provided for @noResultsFor.
  ///
  /// In en, this message translates to:
  /// **'No results for \"{query}\"'**
  String noResultsFor(String query);

  /// No description provided for @yourSavedTitles.
  ///
  /// In en, this message translates to:
  /// **'Your saved titles'**
  String get yourSavedTitles;

  /// No description provided for @myListPlusTrackers.
  ///
  /// In en, this message translates to:
  /// **'My List + {count} {count, plural, one{tracker} other{trackers}}'**
  String myListPlusTrackers(int count);

  /// No description provided for @sort.
  ///
  /// In en, this message translates to:
  /// **'Sort'**
  String get sort;

  /// No description provided for @giveItAName.
  ///
  /// In en, this message translates to:
  /// **'Give it a name'**
  String get giveItAName;

  /// No description provided for @youAlreadyHaveThatOne.
  ///
  /// In en, this message translates to:
  /// **'You already have that one'**
  String get youAlreadyHaveThatOne;

  /// No description provided for @thatNameIsTaken.
  ///
  /// In en, this message translates to:
  /// **'That name is taken'**
  String get thatNameIsTaken;

  /// No description provided for @notConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get notConnected;

  /// No description provided for @connectedWithViewer.
  ///
  /// In en, this message translates to:
  /// **'Connected · {name}'**
  String connectedWithViewer(String name);

  /// No description provided for @allTypes.
  ///
  /// In en, this message translates to:
  /// **'All types'**
  String get allTypes;

  /// No description provided for @nothingHereInThisFilter.
  ///
  /// In en, this message translates to:
  /// **'Nothing here in this filter'**
  String get nothingHereInThisFilter;

  /// No description provided for @noMangaHereInThisFilter.
  ///
  /// In en, this message translates to:
  /// **'No manga here in this filter'**
  String get noMangaHereInThisFilter;

  /// No description provided for @noNovelsHereInThisFilter.
  ///
  /// In en, this message translates to:
  /// **'No novels here in this filter'**
  String get noNovelsHereInThisFilter;

  /// No description provided for @mangaYouAddAppearHere.
  ///
  /// In en, this message translates to:
  /// **'Manga you add appear here'**
  String get mangaYouAddAppearHere;

  /// No description provided for @novelsYouAddAppearHere.
  ///
  /// In en, this message translates to:
  /// **'Novels you add appear here'**
  String get novelsYouAddAppearHere;

  /// No description provided for @relations.
  ///
  /// In en, this message translates to:
  /// **'Relations'**
  String get relations;

  /// No description provided for @characters.
  ///
  /// In en, this message translates to:
  /// **'Characters'**
  String get characters;

  /// No description provided for @noCastInformation.
  ///
  /// In en, this message translates to:
  /// **'No cast information'**
  String get noCastInformation;

  /// No description provided for @noRelatedTitles.
  ///
  /// In en, this message translates to:
  /// **'No related titles'**
  String get noRelatedTitles;

  /// No description provided for @markedAsWatched.
  ///
  /// In en, this message translates to:
  /// **'Marked as watched'**
  String get markedAsWatched;

  /// No description provided for @markedUnwatched.
  ///
  /// In en, this message translates to:
  /// **'Marked unwatched'**
  String get markedUnwatched;

  /// No description provided for @markedEpisodesAsWatched.
  ///
  /// In en, this message translates to:
  /// **'Marked {count} episodes as watched'**
  String markedEpisodesAsWatched(int count);

  /// No description provided for @downloadChaptersQuestion.
  ///
  /// In en, this message translates to:
  /// **'Download {count} chapters?'**
  String downloadChaptersQuestion(int count);

  /// No description provided for @cachedSourceJsFiles.
  ///
  /// In en, this message translates to:
  /// **'Cached source .js files'**
  String get cachedSourceJsFiles;

  /// No description provided for @disconnectTrackerQuestion.
  ///
  /// In en, this message translates to:
  /// **'Disconnect {name}?'**
  String disconnectTrackerQuestion(String name);

  /// No description provided for @trackerDisconnectBody.
  ///
  /// In en, this message translates to:
  /// **'Auto-sync will stop. Your {name} account is not changed — you can reconnect anytime.'**
  String trackerDisconnectBody(String name);

  /// No description provided for @connectedAs.
  ///
  /// In en, this message translates to:
  /// **'Connected as {name}'**
  String connectedAs(String name);

  /// No description provided for @trackerConnectionCanceled.
  ///
  /// In en, this message translates to:
  /// **'{name} connection canceled'**
  String trackerConnectionCanceled(String name);

  /// No description provided for @connectTracker.
  ///
  /// In en, this message translates to:
  /// **'Connect {name}'**
  String connectTracker(String name);

  /// No description provided for @connectingEllipsis.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connectingEllipsis;

  /// No description provided for @updateTrackerAsYouWatch.
  ///
  /// In en, this message translates to:
  /// **'Update {name} as you watch'**
  String updateTrackerAsYouWatch(String name);

  /// No description provided for @findingTitle.
  ///
  /// In en, this message translates to:
  /// **'Finding \"{title}\"…'**
  String findingTitle(String title);

  /// No description provided for @titleIsntOnThisSource.
  ///
  /// In en, this message translates to:
  /// **'\"{title}\" isn\'t on this source'**
  String titleIsntOnThisSource(String title);

  /// No description provided for @couldntOpenTitle.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open \"{title}\"'**
  String couldntOpenTitle(String title);

  /// No description provided for @noWebPageForThisSource.
  ///
  /// In en, this message translates to:
  /// **'No web page for this source'**
  String get noWebPageForThisSource;

  /// No description provided for @couldNotOpenSourceSite.
  ///
  /// In en, this message translates to:
  /// **'Could not open the source site'**
  String get couldNotOpenSourceSite;

  /// No description provided for @notificationsOffFor.
  ///
  /// In en, this message translates to:
  /// **'Notifications off for \"{title}\"'**
  String notificationsOffFor(String title);

  /// No description provided for @youllBeNotifiedOfNewEpisodesFor.
  ///
  /// In en, this message translates to:
  /// **'You\'ll be notified of new episodes of \"{title}\"'**
  String youllBeNotifiedOfNewEpisodesFor(String title);

  /// No description provided for @youllBeNotifiedOfNewChaptersFor.
  ///
  /// In en, this message translates to:
  /// **'You\'ll be notified of new chapters of \"{title}\"'**
  String youllBeNotifiedOfNewChaptersFor(String title);

  /// No description provided for @external.
  ///
  /// In en, this message translates to:
  /// **'External'**
  String get external;

  /// No description provided for @episodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Episode {number}'**
  String episodeLabel(int number);

  /// No description provided for @downloadSeasonEpisode.
  ///
  /// In en, this message translates to:
  /// **'Download S{season}:E{episode}'**
  String downloadSeasonEpisode(int season, int episode);

  /// No description provided for @downloadEpisodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Download E{episode}'**
  String downloadEpisodeLabel(int episode);

  /// No description provided for @continueLabel.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueLabel;

  /// No description provided for @continueEpisode.
  ///
  /// In en, this message translates to:
  /// **'Continue E{episode}'**
  String continueEpisode(int episode);

  /// No description provided for @noEpisodesToDownload.
  ///
  /// In en, this message translates to:
  /// **'No episodes to download'**
  String get noEpisodesToDownload;

  /// No description provided for @addedToDownloads.
  ///
  /// In en, this message translates to:
  /// **'Added to downloads'**
  String get addedToDownloads;

  /// No description provided for @downloadingNEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Downloading {count} episodes'**
  String downloadingNEpisodes(int count);

  /// No description provided for @addToMyList.
  ///
  /// In en, this message translates to:
  /// **'Add to My List'**
  String get addToMyList;

  /// No description provided for @notifyOnNewChapters.
  ///
  /// In en, this message translates to:
  /// **'Notify on new chapters'**
  String get notifyOnNewChapters;

  /// No description provided for @notifyOnNewEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Notify on new episodes'**
  String get notifyOnNewEpisodes;

  /// No description provided for @syncStatusScoreProgress.
  ///
  /// In en, this message translates to:
  /// **'Sync status, score & progress'**
  String get syncStatusScoreProgress;

  /// No description provided for @seasonCount.
  ///
  /// In en, this message translates to:
  /// **'{count} Seasons'**
  String seasonCount(int count);

  /// No description provided for @episodeCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 Episode} other{{count} Episodes}}'**
  String episodeCount(int count);

  /// No description provided for @chapterCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 Chapter} other{{count} Chapters}}'**
  String chapterCount(int count);

  /// No description provided for @thisSourceNeedsSpecialHeadersUsingBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'This source needs special headers your external player can\'t send — using the built-in player.'**
  String get thisSourceNeedsSpecialHeadersUsingBuiltIn;

  /// No description provided for @timerMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count} minutes'**
  String timerMinutes(int count);

  /// No description provided for @couldNotLoadSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load subtitle: {error}'**
  String couldNotLoadSubtitle(String error);

  /// No description provided for @speed.
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get speed;

  /// No description provided for @styledSubtitlesLibassSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Real .ass styling — signs, karaoke. Reopen episode to apply.'**
  String get styledSubtitlesLibassSubtitle;

  /// No description provided for @couldntDownloadFile.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t download {file}'**
  String couldntDownloadFile(String file);

  /// No description provided for @audioNormalizationSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Evens out the volume — boosts quiet dialogue, tames loud scenes'**
  String get audioNormalizationSubtitle;

  /// No description provided for @playbackSpeed.
  ///
  /// In en, this message translates to:
  /// **'Playback Speed'**
  String get playbackSpeed;

  /// No description provided for @quality.
  ///
  /// In en, this message translates to:
  /// **'Quality'**
  String get quality;

  /// No description provided for @sources.
  ///
  /// In en, this message translates to:
  /// **'Sources'**
  String get sources;

  /// No description provided for @normalSpeed.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get normalSpeed;

  /// No description provided for @subtitles.
  ///
  /// In en, this message translates to:
  /// **'Subtitles'**
  String get subtitles;

  /// No description provided for @preferredLanguageColon.
  ///
  /// In en, this message translates to:
  /// **'Preferred language: {name}'**
  String preferredLanguageColon(String name);

  /// No description provided for @nextCount.
  ///
  /// In en, this message translates to:
  /// **'Next {count}'**
  String nextCount(int count);

  /// No description provided for @allCount.
  ///
  /// In en, this message translates to:
  /// **'All {count}'**
  String allCount(int count);

  /// No description provided for @notSavedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} not saved'**
  String notSavedCount(int count);

  /// No description provided for @airsIn.
  ///
  /// In en, this message translates to:
  /// **'airs in '**
  String get airsIn;

  /// No description provided for @selectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get selectAll;

  /// No description provided for @best.
  ///
  /// In en, this message translates to:
  /// **'Best'**
  String get best;

  /// No description provided for @direct.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get direct;

  /// No description provided for @hls.
  ///
  /// In en, this message translates to:
  /// **'HLS'**
  String get hls;

  /// No description provided for @serverWithHost.
  ///
  /// In en, this message translates to:
  /// **'Server {number} · {host}'**
  String serverWithHost(int number, String host);

  /// No description provided for @serverNumber.
  ///
  /// In en, this message translates to:
  /// **'Server {number}'**
  String serverNumber(int number);

  /// No description provided for @downloadCountEpisodes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Download 1 episode} other{Download {count} episodes}}'**
  String downloadCountEpisodes(int count);

  /// No description provided for @chapterOneAtATimeWarning.
  ///
  /// In en, this message translates to:
  /// **'This runs one chapter at a time and can take a long while. You can stop it from Downloads.'**
  String get chapterOneAtATimeWarning;

  /// No description provided for @queuedChapters.
  ///
  /// In en, this message translates to:
  /// **'Queued {count, plural, one{1 chapter} other{{count} chapters}}'**
  String queuedChapters(int count);

  /// No description provided for @seasonNumber.
  ///
  /// In en, this message translates to:
  /// **'Season {number}'**
  String seasonNumber(int number);

  /// No description provided for @listView.
  ///
  /// In en, this message translates to:
  /// **'List view'**
  String get listView;

  /// No description provided for @gridView.
  ///
  /// In en, this message translates to:
  /// **'Grid view'**
  String get gridView;

  /// No description provided for @refreshingChapters.
  ///
  /// In en, this message translates to:
  /// **'Refreshing chapters…'**
  String get refreshingChapters;

  /// No description provided for @refreshingEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Refreshing episodes…'**
  String get refreshingEpisodes;

  /// No description provided for @chapterLabel.
  ///
  /// In en, this message translates to:
  /// **'Chapter {number}'**
  String chapterLabel(int number);

  /// No description provided for @continueBadge.
  ///
  /// In en, this message translates to:
  /// **'CONTINUE'**
  String get continueBadge;

  /// No description provided for @fillerBadge.
  ///
  /// In en, this message translates to:
  /// **'FILLER'**
  String get fillerBadge;

  /// No description provided for @downloadUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Download unsupported'**
  String get downloadUnsupported;

  /// No description provided for @retryDownload.
  ///
  /// In en, this message translates to:
  /// **'Retry download'**
  String get retryDownload;

  /// No description provided for @downloadEpisode.
  ///
  /// In en, this message translates to:
  /// **'Download episode'**
  String get downloadEpisode;

  /// No description provided for @pauseDownload.
  ///
  /// In en, this message translates to:
  /// **'Pause download'**
  String get pauseDownload;

  /// No description provided for @fromEpisode.
  ///
  /// In en, this message translates to:
  /// **'From E{episode}'**
  String fromEpisode(int episode);

  /// No description provided for @episodeWithTitle.
  ///
  /// In en, this message translates to:
  /// **'E{number}  ·  {title}'**
  String episodeWithTitle(int number, String title);

  /// No description provided for @episodeNumberShort.
  ///
  /// In en, this message translates to:
  /// **'E{number}'**
  String episodeNumberShort(int number);

  /// No description provided for @episodeRange.
  ///
  /// In en, this message translates to:
  /// **'E{first} – E{last}'**
  String episodeRange(int first, int last);

  /// No description provided for @episodeSemanticWithTitle.
  ///
  /// In en, this message translates to:
  /// **'Episode {number}, {title}'**
  String episodeSemanticWithTitle(int number, String title);

  /// No description provided for @searchColon.
  ///
  /// In en, this message translates to:
  /// **'Search: {query}'**
  String searchColon(String query);

  /// No description provided for @decoderColon.
  ///
  /// In en, this message translates to:
  /// **'Decoder · {label}'**
  String decoderColon(String label);

  /// No description provided for @megaSkipDuration.
  ///
  /// In en, this message translates to:
  /// **'MegaSkip duration'**
  String get megaSkipDuration;

  /// No description provided for @settingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTooltip;

  /// No description provided for @episodeCountWithRange.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 episode} other{{count} episodes}} · {range}'**
  String episodeCountWithRange(int count, String range);

  /// No description provided for @sourceTimedOut.
  ///
  /// In en, this message translates to:
  /// **'Timed out'**
  String get sourceTimedOut;

  /// No description provided for @blockedByTheSite.
  ///
  /// In en, this message translates to:
  /// **'Blocked by the site'**
  String get blockedByTheSite;

  /// No description provided for @sourceCouldntBeReached.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t be reached'**
  String get sourceCouldntBeReached;

  /// No description provided for @thatSourceCouldNotBeReached.
  ///
  /// In en, this message translates to:
  /// **'That source could not be reached'**
  String get thatSourceCouldNotBeReached;

  /// No description provided for @noSourceCouldBeReached.
  ///
  /// In en, this message translates to:
  /// **'No source could be reached'**
  String get noSourceCouldBeReached;

  /// No description provided for @andNMore.
  ///
  /// In en, this message translates to:
  /// **'and {count} more'**
  String andNMore(int count);

  /// No description provided for @tryClearingYourFiltersOrSearchDifferentTitle.
  ///
  /// In en, this message translates to:
  /// **'Try clearing your filters or searching a different title.'**
  String get tryClearingYourFiltersOrSearchDifferentTitle;

  /// No description provided for @noModeSourcesYet.
  ///
  /// In en, this message translates to:
  /// **'No {mode} sources yet'**
  String noModeSourcesYet(String mode);

  /// No description provided for @browseRepositories.
  ///
  /// In en, this message translates to:
  /// **'Browse repositories'**
  String get browseRepositories;

  /// No description provided for @filteredSource.
  ///
  /// In en, this message translates to:
  /// **'Filtered · {source}'**
  String filteredSource(String source);

  /// No description provided for @turnAllOn.
  ///
  /// In en, this message translates to:
  /// **'Turn all on'**
  String get turnAllOn;

  /// No description provided for @sortUpper.
  ///
  /// In en, this message translates to:
  /// **'SORT'**
  String get sortUpper;

  /// No description provided for @typeUpper.
  ///
  /// In en, this message translates to:
  /// **'TYPE'**
  String get typeUpper;

  /// No description provided for @audioUpper.
  ///
  /// In en, this message translates to:
  /// **'AUDIO'**
  String get audioUpper;

  /// No description provided for @genreUpper.
  ///
  /// In en, this message translates to:
  /// **'GENRE'**
  String get genreUpper;

  /// No description provided for @movieLabel.
  ///
  /// In en, this message translates to:
  /// **'Movie'**
  String get movieLabel;

  /// No description provided for @speakTheTitle.
  ///
  /// In en, this message translates to:
  /// **'Speak the title'**
  String get speakTheTitle;

  /// No description provided for @signedIn.
  ///
  /// In en, this message translates to:
  /// **'Signed in'**
  String get signedIn;

  /// No description provided for @syncYourListNav.
  ///
  /// In en, this message translates to:
  /// **'Sync your list'**
  String get syncYourListNav;

  /// No description provided for @sourceNavLabel.
  ///
  /// In en, this message translates to:
  /// **'SOURCE'**
  String get sourceNavLabel;

  /// No description provided for @activeSourceHint.
  ///
  /// In en, this message translates to:
  /// **'current'**
  String get activeSourceHint;

  /// No description provided for @clearKindHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear {kind} history?'**
  String clearKindHistoryTitle(String kind);

  /// No description provided for @clearKindHistoryBody.
  ///
  /// In en, this message translates to:
  /// **'This removes every {noun} from your {kind} history. Your other history, list and downloads are untouched.'**
  String clearKindHistoryBody(String noun, String kind);

  /// No description provided for @showsYouWatchWillAppearHere.
  ///
  /// In en, this message translates to:
  /// **'Shows you watch will appear here so you can pick up where you left off.'**
  String get showsYouWatchWillAppearHere;

  /// No description provided for @mangaYouReadWillAppearHere.
  ///
  /// In en, this message translates to:
  /// **'Manga you read will appear here so you can pick up where you left off.'**
  String get mangaYouReadWillAppearHere;

  /// No description provided for @novelsYouReadWillAppearHere.
  ///
  /// In en, this message translates to:
  /// **'Novels you read will appear here so you can pick up where you left off.'**
  String get novelsYouReadWillAppearHere;

  /// No description provided for @episodeWatchedPct.
  ///
  /// In en, this message translates to:
  /// **'Episode {number} · {percent}% watched'**
  String episodeWatchedPct(int number, int percent);

  /// No description provided for @percentWatched.
  ///
  /// In en, this message translates to:
  /// **'{percent}% watched'**
  String percentWatched(int percent);

  /// No description provided for @addSourceFromProvidersHint.
  ///
  /// In en, this message translates to:
  /// **'Add a source from Providers and your {content} will show up here.'**
  String addSourceFromProvidersHint(String content);

  /// No description provided for @continueDotEpisode.
  ///
  /// In en, this message translates to:
  /// **'Continue · E{episode}'**
  String continueDotEpisode(int episode);

  /// No description provided for @sourceNameItemCount.
  ///
  /// In en, this message translates to:
  /// **'{name}  ·  {count}'**
  String sourceNameItemCount(String name, int count);

  /// No description provided for @sourceCountBadge.
  ///
  /// In en, this message translates to:
  /// **'{sourceName} {count}'**
  String sourceCountBadge(String sourceName, int count);

  /// No description provided for @logOutQuestion.
  ///
  /// In en, this message translates to:
  /// **'Log out?'**
  String get logOutQuestion;

  /// No description provided for @contentShows.
  ///
  /// In en, this message translates to:
  /// **'shows'**
  String get contentShows;

  /// No description provided for @contentManga.
  ///
  /// In en, this message translates to:
  /// **'manga'**
  String get contentManga;

  /// No description provided for @contentNovels.
  ///
  /// In en, this message translates to:
  /// **'novels'**
  String get contentNovels;

  /// No description provided for @historyKindWatch.
  ///
  /// In en, this message translates to:
  /// **'watch'**
  String get historyKindWatch;

  /// No description provided for @historyKindManga.
  ///
  /// In en, this message translates to:
  /// **'manga'**
  String get historyKindManga;

  /// No description provided for @historyKindNovel.
  ///
  /// In en, this message translates to:
  /// **'novel'**
  String get historyKindNovel;

  /// No description provided for @historyNounShow.
  ///
  /// In en, this message translates to:
  /// **'show'**
  String get historyNounShow;

  /// No description provided for @historyNounMangaItem.
  ///
  /// In en, this message translates to:
  /// **'manga'**
  String get historyNounMangaItem;

  /// No description provided for @historyNounNovelItem.
  ///
  /// In en, this message translates to:
  /// **'novel'**
  String get historyNounNovelItem;

  /// No description provided for @qualityAndAudio.
  ///
  /// In en, this message translates to:
  /// **'Quality & audio'**
  String get qualityAndAudio;

  /// No description provided for @sectionPlayer.
  ///
  /// In en, this message translates to:
  /// **'Player'**
  String get sectionPlayer;

  /// No description provided for @sectionGestures.
  ///
  /// In en, this message translates to:
  /// **'Gestures'**
  String get sectionGestures;

  /// No description provided for @sectionCache.
  ///
  /// In en, this message translates to:
  /// **'Cache'**
  String get sectionCache;

  /// No description provided for @gestures.
  ///
  /// In en, this message translates to:
  /// **'Gestures'**
  String get gestures;

  /// No description provided for @cache.
  ///
  /// In en, this message translates to:
  /// **'Cache'**
  String get cache;

  /// No description provided for @social.
  ///
  /// In en, this message translates to:
  /// **'Social'**
  String get social;

  /// No description provided for @appSection.
  ///
  /// In en, this message translates to:
  /// **'App'**
  String get appSection;

  /// No description provided for @team.
  ///
  /// In en, this message translates to:
  /// **'Team'**
  String get team;

  /// No description provided for @communityContributors.
  ///
  /// In en, this message translates to:
  /// **'Community Contributors'**
  String get communityContributors;

  /// No description provided for @accentColour.
  ///
  /// In en, this message translates to:
  /// **'Accent colour'**
  String get accentColour;

  /// No description provided for @display.
  ///
  /// In en, this message translates to:
  /// **'Display'**
  String get display;

  /// No description provided for @appIcon.
  ///
  /// In en, this message translates to:
  /// **'App icon'**
  String get appIcon;

  /// No description provided for @currentLocation.
  ///
  /// In en, this message translates to:
  /// **'Current location'**
  String get currentLocation;

  /// No description provided for @availableDrives.
  ///
  /// In en, this message translates to:
  /// **'Available drives'**
  String get availableDrives;

  /// No description provided for @dataSection.
  ///
  /// In en, this message translates to:
  /// **'Data'**
  String get dataSection;

  /// No description provided for @modeLabel.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get modeLabel;

  /// No description provided for @tapAZoneToChangeIt.
  ///
  /// In en, this message translates to:
  /// **'Tap a zone to change it'**
  String get tapAZoneToChangeIt;

  /// No description provided for @supportTitle.
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get supportTitle;

  /// No description provided for @enjoyingApp.
  ///
  /// In en, this message translates to:
  /// **'Enjoying {appName}?'**
  String enjoyingApp(String appName);

  /// No description provided for @donateBlurb.
  ///
  /// In en, this message translates to:
  /// **'{appName} is free and ad-free. If it\'s earned a spot on your home screen, a small tip keeps it growing — new features, fixes and faster updates. Every bit genuinely helps. Thank you! ♥'**
  String donateBlurb(String appName);

  /// No description provided for @upiIdCopied.
  ///
  /// In en, this message translates to:
  /// **'UPI ID copied'**
  String get upiIdCopied;

  /// No description provided for @upiIndia.
  ///
  /// In en, this message translates to:
  /// **'UPI · India'**
  String get upiIndia;

  /// No description provided for @askBeforeJumpingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Opening something other than where you left off offers to look without moving your progress'**
  String get askBeforeJumpingSubtitle;

  /// No description provided for @autoTrackSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Update AniList, MyAnimeList and Simkl as you watch. Off still lets you track a title by hand'**
  String get autoTrackSubtitle;

  /// No description provided for @closeConfirmationAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask before leaving the player'**
  String get closeConfirmationAsk;

  /// No description provided for @closeConfirmationDirect.
  ///
  /// In en, this message translates to:
  /// **'Exit immediately'**
  String get closeConfirmationDirect;

  /// No description provided for @closeConfirmationDoubleBack.
  ///
  /// In en, this message translates to:
  /// **'Press back twice to exit'**
  String get closeConfirmationDoubleBack;

  /// No description provided for @autoSkipFillerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Jump past filler when going to the next episode (anime only)'**
  String get autoSkipFillerSubtitle;

  /// No description provided for @playTrailersInHDSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Up to 1080p when available — falls back to standard if not. Uses more data'**
  String get playTrailersInHDSubtitle;

  /// No description provided for @nativeTvPlayerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Recommended. Turn off only if you prefer the old player'**
  String get nativeTvPlayerSubtitle;

  /// No description provided for @softwareAudioSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Turn on only if Dolby/DTS audio is silent — may be unstable on some TVs'**
  String get softwareAudioSubtitle;

  /// No description provided for @playerInfoOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get playerInfoOff;

  /// No description provided for @playerInfoFieldsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} fields (ⓘ button)'**
  String playerInfoFieldsCount(int count);

  /// No description provided for @downloadingPercent.
  ///
  /// In en, this message translates to:
  /// **'Downloading… {percent}%'**
  String downloadingPercent(int percent);

  /// No description provided for @tapToDownloadShaders.
  ///
  /// In en, this message translates to:
  /// **'Tap to download shaders (~0.8 MB)'**
  String get tapToDownloadShaders;

  /// No description provided for @noOtherVideoAppsFound.
  ///
  /// In en, this message translates to:
  /// **'No other video apps found. Install MX Player, VLC, mpv, Just Player or Next Player.'**
  String get noOtherVideoAppsFound;

  /// No description provided for @externalApp.
  ///
  /// In en, this message translates to:
  /// **'External app'**
  String get externalApp;

  /// No description provided for @noSubsResumeSuffix.
  ///
  /// In en, this message translates to:
  /// **' ·  no subs/resume'**
  String get noSubsResumeSuffix;

  /// No description provided for @pickWhatShowsOverVideo.
  ///
  /// In en, this message translates to:
  /// **'Pick what shows over the video (appears with the controls). Like YouTube\'s \"Stats for nerds\".'**
  String get pickWhatShowsOverVideo;

  /// No description provided for @styledSubtitlesLibassSubtitlePlayback.
  ///
  /// In en, this message translates to:
  /// **'Real .ass styling — fonts, positions, karaoke, signs. Best for anime. Applies from the next episode.'**
  String get styledSubtitlesLibassSubtitlePlayback;

  /// No description provided for @subtitleStyleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Font, colour, outline, opacity, size, position — with live preview'**
  String get subtitleStyleSubtitle;

  /// No description provided for @keySavedOnlineSearchEnabled.
  ///
  /// In en, this message translates to:
  /// **'Key saved — online search enabled'**
  String get keySavedOnlineSearchEnabled;

  /// No description provided for @incognitoModeBlurb.
  ///
  /// In en, this message translates to:
  /// **'While on, searches, watch history, tracker scrobbling and Discord presence are paused — nothing is recorded until you turn it off.'**
  String get incognitoModeBlurb;

  /// No description provided for @enableNsfwSourcesBody.
  ///
  /// In en, this message translates to:
  /// **'This shows sources marked 18+ in the source list and switcher. Only turn this on if you want adult content.'**
  String get enableNsfwSourcesBody;

  /// No description provided for @showNsfwAniyomiSourcesBody.
  ///
  /// In en, this message translates to:
  /// **'This shows Aniyomi extensions flagged as 18+ in the source list and switcher. Only turn this on if you want adult content.'**
  String get showNsfwAniyomiSourcesBody;

  /// No description provided for @sourcesMarked18Hidden.
  ///
  /// In en, this message translates to:
  /// **'Sources marked 18+ stay hidden from the source list and switcher unless this is on.'**
  String get sourcesMarked18Hidden;

  /// No description provided for @syncProgressAsYouWatch.
  ///
  /// In en, this message translates to:
  /// **'Sync progress as you watch'**
  String get syncProgressAsYouWatch;

  /// No description provided for @connectionsBlurb.
  ///
  /// In en, this message translates to:
  /// **'Sync watch progress and list status to your accounts. Anime syncs to all three; movies and series sync to Simkl.'**
  String get connectionsBlurb;

  /// No description provided for @connectDiscord.
  ///
  /// In en, this message translates to:
  /// **'Connect Discord'**
  String get connectDiscord;

  /// No description provided for @signInSoYourStatusCanShow.
  ///
  /// In en, this message translates to:
  /// **'Sign in so your status can show on your profile'**
  String get signInSoYourStatusCanShow;

  /// No description provided for @disconnectDiscordBody.
  ///
  /// In en, this message translates to:
  /// **'Rich Presence stops and your token is removed from this device. Your Discord account is not changed — you can reconnect anytime.'**
  String get disconnectDiscordBody;

  /// No description provided for @discordPresenceBlurb.
  ///
  /// In en, this message translates to:
  /// **'Shows \"Watching <title> • Episode N\" (and what you\'re browsing) on your Discord profile while the app is open. Uses your Discord login, stored only on this device. Turn off anytime.'**
  String get discordPresenceBlurb;

  /// No description provided for @github.
  ///
  /// In en, this message translates to:
  /// **'GitHub'**
  String get github;

  /// No description provided for @telegram.
  ///
  /// In en, this message translates to:
  /// **'Telegram'**
  String get telegram;

  /// No description provided for @accentColourBlurb.
  ///
  /// In en, this message translates to:
  /// **'The highlight colour used across buttons, chips, progress and selected items.'**
  String get accentColourBlurb;

  /// No description provided for @appIconBlurb.
  ///
  /// In en, this message translates to:
  /// **'The icon on your home screen. Zangetsu closes when you change it — Android has to swap the launcher entry.'**
  String get appIconBlurb;

  /// No description provided for @useTheIcon.
  ///
  /// In en, this message translates to:
  /// **'Use the {label} icon?'**
  String useTheIcon(String label);

  /// No description provided for @useTheIconBody.
  ///
  /// In en, this message translates to:
  /// **'Zangetsu will close so Android can apply the new icon. Open it again from your home screen afterwards.\n\nIf you have Zangetsu in a folder or dock, you may need to add it again.'**
  String get useTheIconBody;

  /// No description provided for @animRise.
  ///
  /// In en, this message translates to:
  /// **'Rise'**
  String get animRise;

  /// No description provided for @animRiseDesc.
  ///
  /// In en, this message translates to:
  /// **'Lifts and fades in'**
  String get animRiseDesc;

  /// No description provided for @animFade.
  ///
  /// In en, this message translates to:
  /// **'Fade'**
  String get animFade;

  /// No description provided for @animFadeDesc.
  ///
  /// In en, this message translates to:
  /// **'Fades in, no movement'**
  String get animFadeDesc;

  /// No description provided for @animZoom.
  ///
  /// In en, this message translates to:
  /// **'Zoom'**
  String get animZoom;

  /// No description provided for @animZoomDesc.
  ///
  /// In en, this message translates to:
  /// **'Scales up as it appears'**
  String get animZoomDesc;

  /// No description provided for @usedInVerticalMode.
  ///
  /// In en, this message translates to:
  /// **'Used in vertical mode, where the chapter is one continuous strip.'**
  String get usedInVerticalMode;

  /// No description provided for @usedWhenPagesTurn.
  ///
  /// In en, this message translates to:
  /// **'Used when pages turn left and right. In right-to-left mode the two paging zones swap over.'**
  String get usedWhenPagesTurn;

  /// No description provided for @openPullRequestOnGitHub.
  ///
  /// In en, this message translates to:
  /// **'Open a pull request on GitHub and your name shows up here automatically.'**
  String get openPullRequestOnGitHub;

  /// No description provided for @onThisDevice.
  ///
  /// In en, this message translates to:
  /// **'On this device'**
  String get onThisDevice;

  /// No description provided for @newDownloadsSaveHere.
  ///
  /// In en, this message translates to:
  /// **'New downloads save here. Downloads that already finished stay where they were.'**
  String get newDownloadsSaveHere;

  /// No description provided for @torrentsOffWifiBlurb.
  ///
  /// In en, this message translates to:
  /// **'Off = torrents only run on Wi-Fi (saves mobile data). Streaming a torrent uses a lot of data.'**
  String get torrentsOffWifiBlurb;

  /// No description provided for @everyControlIsOnABar.
  ///
  /// In en, this message translates to:
  /// **'Every control is on a bar.'**
  String get everyControlIsOnABar;

  /// No description provided for @nothingHereMoveControl.
  ///
  /// In en, this message translates to:
  /// **'Nothing here — move a control across with Move.'**
  String get nothingHereMoveControl;

  /// No description provided for @playerControlsHelp.
  ///
  /// In en, this message translates to:
  /// **'Drag to reorder within a bar. Use Move to send a control somewhere else. Hidden controls are still available in the ⋮ More menu inside the player.\n\nBack, Lock and Settings are fixed in the top bar, and the show title shares that row — the more you put up there, the less room the title has.'**
  String get playerControlsHelp;

  /// No description provided for @topBarFull.
  ///
  /// In en, this message translates to:
  /// **'{label} (full)'**
  String topBarFull(String label);

  /// No description provided for @apiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get apiKeyLabel;

  /// No description provided for @secondsShort.
  ///
  /// In en, this message translates to:
  /// **'{count}s'**
  String secondsShort(int count);

  /// No description provided for @gotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get gotIt;

  /// No description provided for @signInToAction.
  ///
  /// In en, this message translates to:
  /// **'Sign in to {action}'**
  String signInToAction(String action);

  /// No description provided for @cloudBackupFailed.
  ///
  /// In en, this message translates to:
  /// **'Cloud backup failed. Check you\'re online — if it keeps failing, the cloud backup store may not be set up yet.'**
  String get cloudBackupFailed;

  /// No description provided for @savedToDownloadsZangetsu.
  ///
  /// In en, this message translates to:
  /// **'Saved to Downloads › Zangetsu'**
  String get savedToDownloadsZangetsu;

  /// No description provided for @restoreFailed.
  ///
  /// In en, this message translates to:
  /// **'Restore failed: {error}'**
  String restoreFailed(String error);

  /// No description provided for @noBackupFilesOnDevice.
  ///
  /// In en, this message translates to:
  /// **'No backup files found on this device. Save one first, or use \"Restore from cloud\".'**
  String get noBackupFilesOnDevice;

  /// No description provided for @backupScreenBlurb.
  ///
  /// In en, this message translates to:
  /// **'Save your sources, list and settings — to a file on your device or to your Zangetsu account. Restoring only adds things back; it never deletes what you already have.'**
  String get backupScreenBlurb;

  /// No description provided for @includeInTheBackup.
  ///
  /// In en, this message translates to:
  /// **'Include in the backup'**
  String get includeInTheBackup;

  /// No description provided for @sourcesAndRepos.
  ///
  /// In en, this message translates to:
  /// **'Sources & repos'**
  String get sourcesAndRepos;

  /// No description provided for @installedSourcesAndRepoLinks.
  ///
  /// In en, this message translates to:
  /// **'Installed sources and their repo links'**
  String get installedSourcesAndRepoLinks;

  /// No description provided for @libraryBundle.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get libraryBundle;

  /// No description provided for @myListAndContinueWatching.
  ///
  /// In en, this message translates to:
  /// **'My List and Continue Watching'**
  String get myListAndContinueWatching;

  /// No description provided for @appSettingsBundle.
  ///
  /// In en, this message translates to:
  /// **'App settings'**
  String get appSettingsBundle;

  /// No description provided for @playerSubtitlesQualityPreferences.
  ///
  /// In en, this message translates to:
  /// **'Player, subtitles, quality and preferences'**
  String get playerSubtitlesQualityPreferences;

  /// No description provided for @lastCloudBackup.
  ///
  /// In en, this message translates to:
  /// **'Last cloud backup: {when}'**
  String lastCloudBackup(String when);

  /// No description provided for @never.
  ///
  /// In en, this message translates to:
  /// **'never'**
  String get never;

  /// No description provided for @restoredColon.
  ///
  /// In en, this message translates to:
  /// **'Restored: {names}.'**
  String restoredColon(String names);

  /// No description provided for @couldnTReinstall.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reinstall:\n{failures}'**
  String couldnTReinstall(String failures);

  /// No description provided for @onLatestVersion.
  ///
  /// In en, this message translates to:
  /// **'You\'re on the latest version{versionSuffix}.'**
  String onLatestVersion(String versionSuffix);

  /// No description provided for @joinBetaUpdatesBody.
  ///
  /// In en, this message translates to:
  /// **'You\'ll get pre-release builds early. They can be unstable — if one acts up, just turn this off and you\'ll move back to stable on the next update. You can leave anytime.'**
  String get joinBetaUpdatesBody;

  /// No description provided for @betaUpdateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Beta update available'**
  String get betaUpdateAvailable;

  /// No description provided for @updateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get updateAvailable;

  /// No description provided for @startingInstaller.
  ///
  /// In en, this message translates to:
  /// **'Starting installer…'**
  String get startingInstaller;

  /// No description provided for @couldnTOpenInstaller.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open the installer. Enable \"Install unknown apps\" for Zangetsu in system settings, then try again.'**
  String get couldnTOpenInstaller;

  /// No description provided for @downloadFailedCheckConnection.
  ///
  /// In en, this message translates to:
  /// **'Download failed — check your connection and try again.'**
  String get downloadFailedCheckConnection;

  /// No description provided for @libraryIsntSavedReconnect.
  ///
  /// In en, this message translates to:
  /// **'Your library isn\'t saved to the cloud yet, so logging out will remove it from this device. Reconnect to back it up first?'**
  String get libraryIsntSavedReconnect;

  /// No description provided for @sessionExpiredEnterPassword.
  ///
  /// In en, this message translates to:
  /// **'Your session expired. Enter your password to reconnect {account} and sync your library.'**
  String sessionExpiredEnterPassword(String account);

  /// No description provided for @yourAccount.
  ///
  /// In en, this message translates to:
  /// **'your account'**
  String get yourAccount;

  /// No description provided for @reconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get reconnecting;

  /// No description provided for @wrongPassword.
  ///
  /// In en, this message translates to:
  /// **'Wrong password'**
  String get wrongPassword;

  /// No description provided for @trackersSynced.
  ///
  /// In en, this message translates to:
  /// **'Trackers synced: {list}'**
  String trackersSynced(String list);

  /// No description provided for @signInOnDevice.
  ///
  /// In en, this message translates to:
  /// **'Sign in on {device}?'**
  String signInOnDevice(String device);

  /// No description provided for @thisTV.
  ///
  /// In en, this message translates to:
  /// **'this TV'**
  String get thisTV;

  /// No description provided for @announcements.
  ///
  /// In en, this message translates to:
  /// **'Announcements'**
  String get announcements;

  /// No description provided for @subscribedShows.
  ///
  /// In en, this message translates to:
  /// **'Subscribed shows'**
  String get subscribedShows;

  /// No description provided for @noNotificationsYet.
  ///
  /// In en, this message translates to:
  /// **'No notifications yet.\nTap the bell on a show to get alerted when a new episode is out.'**
  String get noNotificationsYet;

  /// No description provided for @hostBadge.
  ///
  /// In en, this message translates to:
  /// **'HOST'**
  String get hostBadge;

  /// No description provided for @controlGivenTo.
  ///
  /// In en, this message translates to:
  /// **'Control given to {name}'**
  String controlGivenTo(String name);

  /// No description provided for @youReTheHost.
  ///
  /// In en, this message translates to:
  /// **'You\'re the host'**
  String get youReTheHost;

  /// No description provided for @couldnTCreateParty.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t create party: {error}'**
  String couldnTCreateParty(String error);

  /// No description provided for @series.
  ///
  /// In en, this message translates to:
  /// **'Series'**
  String get series;

  /// No description provided for @movie.
  ///
  /// In en, this message translates to:
  /// **'Movie'**
  String get movie;

  /// No description provided for @epWithTime.
  ///
  /// In en, this message translates to:
  /// **'Ep {episode} · {time}'**
  String epWithTime(String episode, String time);

  /// No description provided for @chooseChapterSemantic.
  ///
  /// In en, this message translates to:
  /// **'{title}, {subtitle}. Choose chapter'**
  String chooseChapterSemantic(String title, String subtitle);

  /// No description provided for @chapterProgress.
  ///
  /// In en, this message translates to:
  /// **'Chapter {current} / {total}'**
  String chapterProgress(int current, int total);

  /// No description provided for @chapterNumber.
  ///
  /// In en, this message translates to:
  /// **'Chapter {number}'**
  String chapterNumber(int number);

  /// No description provided for @activeSourceColon.
  ///
  /// In en, this message translates to:
  /// **'Active source: {name}'**
  String activeSourceColon(String name);

  /// No description provided for @settingsSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, settings'**
  String settingsSemantic(String name);

  /// No description provided for @enterTheCodeShownOnTV.
  ///
  /// In en, this message translates to:
  /// **'Enter the code shown on your TV.'**
  String get enterTheCodeShownOnTV;

  /// No description provided for @codeNotFoundExpired.
  ///
  /// In en, this message translates to:
  /// **'That code wasn\'t found — it may have expired.'**
  String get codeNotFoundExpired;

  /// No description provided for @alsoSendTrackers.
  ///
  /// In en, this message translates to:
  /// **'Also send your trackers (AniList, MyAnimeList, Simkl)'**
  String get alsoSendTrackers;

  /// No description provided for @scrollRowsOrSearch.
  ///
  /// In en, this message translates to:
  /// **'Scroll the rows on Home, or tap Search at the bottom.'**
  String get scrollRowsOrSearch;

  /// No description provided for @openTitleAndPlay.
  ///
  /// In en, this message translates to:
  /// **'Open a title and tap Play. For a series, pick an episode first.'**
  String get openTitleAndPlay;

  /// No description provided for @switchSourceAtTop.
  ///
  /// In en, this message translates to:
  /// **'Tap the source name at the top and switch to another source.'**
  String get switchSourceAtTop;

  /// No description provided for @tapDownloadForOffline.
  ///
  /// In en, this message translates to:
  /// **'On a title, tap Download — watch it later under Downloads.'**
  String get tapDownloadForOffline;

  /// No description provided for @faqSourceNotWorkingQ.
  ///
  /// In en, this message translates to:
  /// **'A source isn\'t working?'**
  String get faqSourceNotWorkingQ;

  /// No description provided for @faqSourceNotWorkingA.
  ///
  /// In en, this message translates to:
  /// **'Sources come and go. Switch source from the top, or check Settings → Source health.'**
  String get faqSourceNotWorkingA;

  /// No description provided for @faqSubOrDubQ.
  ///
  /// In en, this message translates to:
  /// **'Sub or Dub?'**
  String get faqSubOrDubQ;

  /// No description provided for @faqSubOrDubA.
  ///
  /// In en, this message translates to:
  /// **'Use the Sub / Dub toggle on an anime title.'**
  String get faqSubOrDubA;

  /// No description provided for @faqDownloadsQ.
  ///
  /// In en, this message translates to:
  /// **'Where are my downloads?'**
  String get faqDownloadsQ;

  /// No description provided for @faqDownloadsA.
  ///
  /// In en, this message translates to:
  /// **'Settings → Downloads — watch them offline anytime.'**
  String get faqDownloadsA;

  /// No description provided for @resetPasswordBody.
  ///
  /// In en, this message translates to:
  /// **'Enter your account email and we\'ll send a link to set a new password.'**
  String get resetPasswordBody;

  /// No description provided for @couldnTSignIn.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t sign in'**
  String get couldnTSignIn;

  /// No description provided for @aniyomi.
  ///
  /// In en, this message translates to:
  /// **'Aniyomi'**
  String get aniyomi;

  /// No description provided for @mihon.
  ///
  /// In en, this message translates to:
  /// **'Mihon'**
  String get mihon;

  /// No description provided for @lnreader.
  ///
  /// In en, this message translates to:
  /// **'LNReader'**
  String get lnreader;

  /// No description provided for @zangetsu.
  ///
  /// In en, this message translates to:
  /// **'Zangetsu'**
  String get zangetsu;

  /// No description provided for @cloudStream.
  ///
  /// In en, this message translates to:
  /// **'CloudStream'**
  String get cloudStream;

  /// No description provided for @installedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} installed'**
  String installedCount(int count);

  /// No description provided for @installedName.
  ///
  /// In en, this message translates to:
  /// **'Installed {name}'**
  String installedName(String name);

  /// No description provided for @uninstalledName.
  ///
  /// In en, this message translates to:
  /// **'Uninstalled {name}'**
  String uninstalledName(String name);

  /// No description provided for @removedName.
  ///
  /// In en, this message translates to:
  /// **'Removed {name}'**
  String removedName(String name);

  /// No description provided for @updatedName.
  ///
  /// In en, this message translates to:
  /// **'Updated {name}'**
  String updatedName(String name);

  /// No description provided for @installFailed.
  ///
  /// In en, this message translates to:
  /// **'Install failed: {error}'**
  String installFailed(String error);

  /// No description provided for @uninstallFailed.
  ///
  /// In en, this message translates to:
  /// **'Uninstall failed: {error}'**
  String uninstallFailed(String error);

  /// No description provided for @removeFailed.
  ///
  /// In en, this message translates to:
  /// **'Remove failed: {error}'**
  String removeFailed(String error);

  /// No description provided for @updateFailed.
  ///
  /// In en, this message translates to:
  /// **'Update failed: {error}'**
  String updateFailed(String error);

  /// No description provided for @checkFailed.
  ///
  /// In en, this message translates to:
  /// **'Check failed: {error}'**
  String checkFailed(String error);

  /// No description provided for @failedToAddRepo.
  ///
  /// In en, this message translates to:
  /// **'Failed to add repo: {error}'**
  String failedToAddRepo(String error);

  /// No description provided for @uninstallNameQuestion.
  ///
  /// In en, this message translates to:
  /// **'Uninstall {name}?'**
  String uninstallNameQuestion(String name);

  /// No description provided for @removeNameQuestion.
  ///
  /// In en, this message translates to:
  /// **'Remove {name}?'**
  String removeNameQuestion(String name);

  /// No description provided for @updateNameToVersion.
  ///
  /// In en, this message translates to:
  /// **'{name}, update to v{version}'**
  String updateNameToVersion(String name, String version);

  /// No description provided for @updateArrowVersion.
  ///
  /// In en, this message translates to:
  /// **'Update → v{version}'**
  String updateArrowVersion(String version);

  /// No description provided for @repoBaseUrl.
  ///
  /// In en, this message translates to:
  /// **'Repo base URL'**
  String get repoBaseUrl;

  /// No description provided for @repoBaseUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://.../repo'**
  String get repoBaseUrlHint;

  /// No description provided for @pluginIndexUrl.
  ///
  /// In en, this message translates to:
  /// **'Plugin index URL'**
  String get pluginIndexUrl;

  /// No description provided for @pluginIndexUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://.../plugins.min.json'**
  String get pluginIndexUrlHint;

  /// No description provided for @manifestUrl.
  ///
  /// In en, this message translates to:
  /// **'Manifest URL'**
  String get manifestUrl;

  /// No description provided for @manifestUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://.../index.json'**
  String get manifestUrlHint;

  /// No description provided for @repoUrl.
  ///
  /// In en, this message translates to:
  /// **'Repo URL'**
  String get repoUrl;

  /// No description provided for @repoUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://.../repo.json'**
  String get repoUrlHint;

  /// No description provided for @customNameOptional.
  ///
  /// In en, this message translates to:
  /// **'Custom name (optional)'**
  String get customNameOptional;

  /// No description provided for @leaveBlankToUseRepo.
  ///
  /// In en, this message translates to:
  /// **'Leave blank to use the repo'**
  String get leaveBlankToUseRepo;

  /// No description provided for @alreadyInstalledSourcesStay.
  ///
  /// In en, this message translates to:
  /// **'Already-installed sources from this repo stay installed. '**
  String get alreadyInstalledSourcesStay;

  /// No description provided for @alreadyInstalledExtensionsStay.
  ///
  /// In en, this message translates to:
  /// **'Already-installed extensions from this repo stay installed. '**
  String get alreadyInstalledExtensionsStay;

  /// No description provided for @updateAllCount.
  ///
  /// In en, this message translates to:
  /// **'Update all ({count})'**
  String updateAllCount(int count);

  /// No description provided for @updatedSourcesCount.
  ///
  /// In en, this message translates to:
  /// **'Updated {done} source{suffix}'**
  String updatedSourcesCount(int done, String suffix);

  /// No description provided for @slow.
  ///
  /// In en, this message translates to:
  /// **'Slow'**
  String get slow;

  /// No description provided for @noResults.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get noResults;

  /// No description provided for @timedOut.
  ///
  /// In en, this message translates to:
  /// **'Timed out'**
  String get timedOut;

  /// No description provided for @blocked.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get blocked;

  /// No description provided for @notUsable.
  ///
  /// In en, this message translates to:
  /// **'Not usable'**
  String get notUsable;

  /// No description provided for @openThisSource.
  ///
  /// In en, this message translates to:
  /// **'Open this source'**
  String get openThisSource;

  /// No description provided for @nameRemovedFromSearch.
  ///
  /// In en, this message translates to:
  /// **'{name} removed from search'**
  String nameRemovedFromSearch(String name);

  /// No description provided for @connectLabel.
  ///
  /// In en, this message translates to:
  /// **'Connect {label}'**
  String connectLabel(String label);

  /// No description provided for @scanToLogInWith.
  ///
  /// In en, this message translates to:
  /// **'Scan to log in with\n{label} in your browser'**
  String scanToLogInWith(String label);

  /// No description provided for @anilist.
  ///
  /// In en, this message translates to:
  /// **'AniList'**
  String get anilist;

  /// No description provided for @myAnimeList.
  ///
  /// In en, this message translates to:
  /// **'MyAnimeList'**
  String get myAnimeList;

  /// No description provided for @simkl.
  ///
  /// In en, this message translates to:
  /// **'Simkl'**
  String get simkl;

  /// No description provided for @code.
  ///
  /// In en, this message translates to:
  /// **'CODE'**
  String get code;

  /// No description provided for @signInToBackUpToCloud.
  ///
  /// In en, this message translates to:
  /// **'back up to the cloud'**
  String get signInToBackUpToCloud;

  /// No description provided for @signInToRestoreFromCloud.
  ///
  /// In en, this message translates to:
  /// **'restore from the cloud'**
  String get signInToRestoreFromCloud;

  /// No description provided for @signInToUseThis.
  ///
  /// In en, this message translates to:
  /// **'use this'**
  String get signInToUseThis;

  /// No description provided for @enabled.
  ///
  /// In en, this message translates to:
  /// **'enabled'**
  String get enabled;

  /// No description provided for @disabled.
  ///
  /// In en, this message translates to:
  /// **'disabled'**
  String get disabled;

  /// No description provided for @sourcesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} sources'**
  String sourcesCount(int count);

  /// No description provided for @removeRepoSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, remove repo'**
  String removeRepoSemantic(String name);

  /// No description provided for @repoDisplaySemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, '**
  String repoDisplaySemantic(String name);

  /// No description provided for @entryInstalledSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, {state}'**
  String entryInstalledSemantic(String name, String state);

  /// No description provided for @repoSourcesCount.
  ///
  /// In en, this message translates to:
  /// **'{name}, {count} sources'**
  String repoSourcesCount(String name, int count);

  /// No description provided for @repoRefreshSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, refresh'**
  String repoRefreshSemantic(String name);

  /// No description provided for @repoUpdateAllSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, update all ({count})'**
  String repoUpdateAllSemantic(String name, int count);

  /// No description provided for @repoRemoveSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, remove'**
  String repoRemoveSemantic(String name);

  /// No description provided for @sourceUpdateSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, update'**
  String sourceUpdateSemantic(String name);

  /// No description provided for @sourceUninstallSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, uninstall'**
  String sourceUninstallSemantic(String name);

  /// No description provided for @sourceInstallSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, install'**
  String sourceInstallSemantic(String name);

  /// No description provided for @sourceSettingsSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, settings'**
  String sourceSettingsSemantic(String name);

  /// No description provided for @sourceRemoveSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, remove'**
  String sourceRemoveSemantic(String name);

  /// No description provided for @sourceEnabledSemantic.
  ///
  /// In en, this message translates to:
  /// **'{name}, {state}'**
  String sourceEnabledSemantic(String name, String state);

  /// No description provided for @titleInstalledCount.
  ///
  /// In en, this message translates to:
  /// **'{title}, {count} installed'**
  String titleInstalledCount(String title, int count);

  /// No description provided for @titleCheckUpdatesSemantic.
  ///
  /// In en, this message translates to:
  /// **'{title}, check updates'**
  String titleCheckUpdatesSemantic(String title);

  /// No description provided for @titleRemoveRepoSemantic.
  ///
  /// In en, this message translates to:
  /// **'{title}, remove repo'**
  String titleRemoveRepoSemantic(String title);

  /// No description provided for @titleApplyUpdatesSemantic.
  ///
  /// In en, this message translates to:
  /// **'{title}, apply {what}'**
  String titleApplyUpdatesSemantic(String title, String what);

  /// No description provided for @oneUpdate.
  ///
  /// In en, this message translates to:
  /// **'1 update'**
  String get oneUpdate;

  /// No description provided for @nUpdates.
  ///
  /// In en, this message translates to:
  /// **'{count} updates'**
  String nUpdates(int count);

  /// No description provided for @percentRead.
  ///
  /// In en, this message translates to:
  /// **'{percent}% read'**
  String percentRead(int percent);

  /// No description provided for @couldntLoadDownloadOptions.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load download options'**
  String get couldntLoadDownloadOptions;

  /// No description provided for @selectedEpisodesOfTotal.
  ///
  /// In en, this message translates to:
  /// **'{selected} of {total} episodes'**
  String selectedEpisodesOfTotal(int selected, int total);

  /// No description provided for @episodeSemantic.
  ///
  /// In en, this message translates to:
  /// **'Episode {number}'**
  String episodeSemantic(int number);

  /// No description provided for @textColour.
  ///
  /// In en, this message translates to:
  /// **'Text colour'**
  String get textColour;

  /// No description provided for @textOpacity.
  ///
  /// In en, this message translates to:
  /// **'Text opacity'**
  String get textOpacity;

  /// No description provided for @outlineStyle.
  ///
  /// In en, this message translates to:
  /// **'Outline style'**
  String get outlineStyle;

  /// No description provided for @outlineColour.
  ///
  /// In en, this message translates to:
  /// **'Outline colour'**
  String get outlineColour;

  /// No description provided for @outlineWidth.
  ///
  /// In en, this message translates to:
  /// **'Outline width'**
  String get outlineWidth;

  /// No description provided for @positionTop.
  ///
  /// In en, this message translates to:
  /// **'Top'**
  String get positionTop;

  /// No description provided for @positionBottom.
  ///
  /// In en, this message translates to:
  /// **'Bottom'**
  String get positionBottom;

  /// No description provided for @subtitleSize.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get subtitleSize;

  /// No description provided for @colourWhite.
  ///
  /// In en, this message translates to:
  /// **'White'**
  String get colourWhite;

  /// No description provided for @colourYellow.
  ///
  /// In en, this message translates to:
  /// **'Yellow'**
  String get colourYellow;

  /// No description provided for @colourGreen.
  ///
  /// In en, this message translates to:
  /// **'Green'**
  String get colourGreen;

  /// No description provided for @colourRed.
  ///
  /// In en, this message translates to:
  /// **'Red'**
  String get colourRed;

  /// No description provided for @colourBlack.
  ///
  /// In en, this message translates to:
  /// **'Black'**
  String get colourBlack;

  /// No description provided for @tapToDownloadFont.
  ///
  /// In en, this message translates to:
  /// **'Tap to download'**
  String get tapToDownloadFont;

  /// No description provided for @subtitleOutlineNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get subtitleOutlineNone;

  /// No description provided for @subtitleOutlineSoft.
  ///
  /// In en, this message translates to:
  /// **'Soft shadow'**
  String get subtitleOutlineSoft;

  /// No description provided for @subtitleOutlineOutline.
  ///
  /// In en, this message translates to:
  /// **'Outline'**
  String get subtitleOutlineOutline;

  /// No description provided for @subtitleOutlineBold.
  ///
  /// In en, this message translates to:
  /// **'Bold outline'**
  String get subtitleOutlineBold;

  /// No description provided for @subtitleOutlineShadow.
  ///
  /// In en, this message translates to:
  /// **'Drop shadow'**
  String get subtitleOutlineShadow;

  /// No description provided for @subtitleOutlineGlow.
  ///
  /// In en, this message translates to:
  /// **'Glow'**
  String get subtitleOutlineGlow;

  /// No description provided for @noSubtitlesFoundFor.
  ///
  /// In en, this message translates to:
  /// **'No subtitles found for \"{query}\".'**
  String noSubtitlesFoundFor(String query);

  /// No description provided for @searchFailedWithError.
  ///
  /// In en, this message translates to:
  /// **'Search failed: {error}'**
  String searchFailedWithError(String error);

  /// No description provided for @downloadFailedWithError.
  ///
  /// In en, this message translates to:
  /// **'Download failed: {error}'**
  String downloadFailedWithError(String error);

  /// No description provided for @decreaseDelay.
  ///
  /// In en, this message translates to:
  /// **'Decrease {label}'**
  String decreaseDelay(String label);

  /// No description provided for @increaseDelay.
  ///
  /// In en, this message translates to:
  /// **'Increase {label}'**
  String increaseDelay(String label);

  /// No description provided for @alignedDelay.
  ///
  /// In en, this message translates to:
  /// **'Aligned {offset}'**
  String alignedDelay(String offset);

  /// No description provided for @subtitleSyncVoiceCaptured.
  ///
  /// In en, this message translates to:
  /// **'Voice captured ✓ — play until the subtitle shows, then tap Subtitle seen. (You can close this sheet meanwhile.)'**
  String get subtitleSyncVoiceCaptured;

  /// No description provided for @subtitleSyncTextCaptured.
  ///
  /// In en, this message translates to:
  /// **'Subtitle captured ✓ — now tap Voice heard when you hear the line.'**
  String get subtitleSyncTextCaptured;

  /// No description provided for @subtitleSyncHint.
  ///
  /// In en, this message translates to:
  /// **'Auto-sync: tap when you HEAR a line, then when its SUBTITLE appears.'**
  String get subtitleSyncHint;

  /// No description provided for @voiceHeard.
  ///
  /// In en, this message translates to:
  /// **'Voice heard'**
  String get voiceHeard;

  /// No description provided for @subtitleSeen.
  ///
  /// In en, this message translates to:
  /// **'Subtitle seen'**
  String get subtitleSeen;

  /// No description provided for @contrast.
  ///
  /// In en, this message translates to:
  /// **'Contrast'**
  String get contrast;

  /// No description provided for @saturation.
  ///
  /// In en, this message translates to:
  /// **'Saturation'**
  String get saturation;

  /// No description provided for @gamma.
  ///
  /// In en, this message translates to:
  /// **'Gamma'**
  String get gamma;

  /// No description provided for @hue.
  ///
  /// In en, this message translates to:
  /// **'Hue'**
  String get hue;

  /// No description provided for @drm.
  ///
  /// In en, this message translates to:
  /// **'DRM'**
  String get drm;

  /// No description provided for @sourceFallback.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get sourceFallback;

  /// No description provided for @expandAll.
  ///
  /// In en, this message translates to:
  /// **'Expand all'**
  String get expandAll;

  /// No description provided for @downloadedSummary.
  ///
  /// In en, this message translates to:
  /// **'{count} downloaded · {size}'**
  String downloadedSummary(int count, String size);

  /// No description provided for @ofTotalDownloaded.
  ///
  /// In en, this message translates to:
  /// **'{done} of {total}'**
  String ofTotalDownloaded(int done, int total);

  /// No description provided for @episodesDownloadedOfTotal.
  ///
  /// In en, this message translates to:
  /// **'{done} of {total} downloaded'**
  String episodesDownloadedOfTotal(int done, int total);

  /// No description provided for @removeAllEpisodesOfShow.
  ///
  /// In en, this message translates to:
  /// **'Remove all {count, plural, one{1 episode} other{{count} episodes}} of \"{title}\" from this device?'**
  String removeAllEpisodesOfShow(int count, String title);

  /// No description provided for @mangaChaptersYouDownloadAppearHere.
  ///
  /// In en, this message translates to:
  /// **'Manga chapters you download appear here'**
  String get mangaChaptersYouDownloadAppearHere;

  /// No description provided for @parallelDownloadsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'How many episodes download at the same time. Chapters always download one at a time.'**
  String get parallelDownloadsSubtitle;

  /// No description provided for @connectionsPerDownloadSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Segment connections an episode uses, and pages fetched at once in a chapter. Higher = faster, more data at once.'**
  String get connectionsPerDownloadSubtitle;

  /// No description provided for @savingToYourFolder.
  ///
  /// In en, this message translates to:
  /// **'Saving to your folder…'**
  String get savingToYourFolder;

  /// No description provided for @notAvailableOfflineYet.
  ///
  /// In en, this message translates to:
  /// **'Not available offline yet'**
  String get notAvailableOfflineYet;

  /// No description provided for @downloadQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get downloadQueued;

  /// No description provided for @downloadPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing…'**
  String get downloadPreparing;

  /// No description provided for @downloadPausedProgress.
  ///
  /// In en, this message translates to:
  /// **'Paused · {percent}%'**
  String downloadPausedProgress(int percent);

  /// No description provided for @downloadProgressPercent.
  ///
  /// In en, this message translates to:
  /// **'{percent}%'**
  String downloadProgressPercent(int percent);

  /// No description provided for @downloadProgressPercentOfSize.
  ///
  /// In en, this message translates to:
  /// **'{percent}% of {size}'**
  String downloadProgressPercentOfSize(int percent, String size);

  /// No description provided for @downloadCanceled.
  ///
  /// In en, this message translates to:
  /// **'Canceled'**
  String get downloadCanceled;

  /// No description provided for @downloadFailedStatus.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get downloadFailedStatus;

  /// No description provided for @peerCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 peer} other{{count} peers}}'**
  String peerCount(int count);

  /// No description provided for @downloadSpeedMbps.
  ///
  /// In en, this message translates to:
  /// **'{speed} MB/s'**
  String downloadSpeedMbps(String speed);

  /// No description provided for @downloadSpeedKbps.
  ///
  /// In en, this message translates to:
  /// **'{speed} KB/s'**
  String downloadSpeedKbps(int speed);

  /// No description provided for @episodeWithTitleDot.
  ///
  /// In en, this message translates to:
  /// **'E{number} · {title}'**
  String episodeWithTitleDot(int number, String title);

  /// No description provided for @mangaDownloads.
  ///
  /// In en, this message translates to:
  /// **'Manga downloads'**
  String get mangaDownloads;

  /// No description provided for @novelDownloads.
  ///
  /// In en, this message translates to:
  /// **'Novel downloads'**
  String get novelDownloads;

  /// No description provided for @downloadingSection.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get downloadingSection;

  /// No description provided for @stopAllCount.
  ///
  /// In en, this message translates to:
  /// **'Stop all ({count})'**
  String stopAllCount(int count);

  /// No description provided for @clearFailedCount.
  ///
  /// In en, this message translates to:
  /// **'Clear failed ({count})'**
  String clearFailedCount(int count);

  /// No description provided for @stopDownloadingBody.
  ///
  /// In en, this message translates to:
  /// **'Cancel {count, plural, one{1 queued chapter} other{{count} queued chapters}}. Chapters already downloaded are kept.'**
  String stopDownloadingBody(int count);

  /// No description provided for @clearedFailedCount.
  ///
  /// In en, this message translates to:
  /// **'Cleared {count} failed'**
  String clearedFailedCount(int count);

  /// No description provided for @chapterPagesProgress.
  ///
  /// In en, this message translates to:
  /// **'{done}/{total} pages'**
  String chapterPagesProgress(int done, int total);

  /// No description provided for @showTitleQueued.
  ///
  /// In en, this message translates to:
  /// **'{title} · Queued'**
  String showTitleQueued(String title);

  /// No description provided for @showTitleDownloading.
  ///
  /// In en, this message translates to:
  /// **'{title} · Downloading…'**
  String showTitleDownloading(String title);

  /// No description provided for @showTitleWithError.
  ///
  /// In en, this message translates to:
  /// **'{title} · {error}'**
  String showTitleWithError(String title, String error);

  /// No description provided for @removeAllChaptersOfShow.
  ///
  /// In en, this message translates to:
  /// **'Remove all {count, plural, one{1 chapter} other{{count} chapters}} of \"{title}\" from this device?'**
  String removeAllChaptersOfShow(int count, String title);

  /// No description provided for @chaptersWithSize.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 chapter} other{{count} chapters}} · {size}'**
  String chaptersWithSize(int count, String size);

  /// No description provided for @deleteAllEpisodesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete all episodes'**
  String get deleteAllEpisodesTooltip;

  /// No description provided for @deleteAllChaptersTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete all chapters'**
  String get deleteAllChaptersTooltip;

  /// No description provided for @cancelDownloadTooltip.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelDownloadTooltip;

  /// No description provided for @removeDownloadTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get removeDownloadTooltip;

  /// No description provided for @positionLabel.
  ///
  /// In en, this message translates to:
  /// **'Position'**
  String get positionLabel;

  /// No description provided for @relativeTomorrow.
  ///
  /// In en, this message translates to:
  /// **'Tomorrow'**
  String get relativeTomorrow;

  /// No description provided for @weekView.
  ///
  /// In en, this message translates to:
  /// **'Week'**
  String get weekView;

  /// No description provided for @monthView.
  ///
  /// In en, this message translates to:
  /// **'Month'**
  String get monthView;

  /// No description provided for @scheduleSlotMorning.
  ///
  /// In en, this message translates to:
  /// **'MORNING'**
  String get scheduleSlotMorning;

  /// No description provided for @scheduleSlotAfternoon.
  ///
  /// In en, this message translates to:
  /// **'AFTERNOON'**
  String get scheduleSlotAfternoon;

  /// No description provided for @scheduleSlotEvening.
  ///
  /// In en, this message translates to:
  /// **'EVENING'**
  String get scheduleSlotEvening;

  /// No description provided for @scheduleSlotLateNight.
  ///
  /// In en, this message translates to:
  /// **'LATE NIGHT'**
  String get scheduleSlotLateNight;

  /// No description provided for @nothingAiringOnThisDay.
  ///
  /// In en, this message translates to:
  /// **'Nothing airing on this day.'**
  String get nothingAiringOnThisDay;

  /// No description provided for @nothingReleasingOnThisDay.
  ///
  /// In en, this message translates to:
  /// **'Nothing releasing on this day.'**
  String get nothingReleasingOnThisDay;

  /// No description provided for @noneOfFollowedAirOnThisDay.
  ///
  /// In en, this message translates to:
  /// **'None of the anime you follow air on this day.'**
  String get noneOfFollowedAirOnThisDay;

  /// No description provided for @scheduleAired.
  ///
  /// In en, this message translates to:
  /// **'Aired'**
  String get scheduleAired;

  /// No description provided for @scheduleLive.
  ///
  /// In en, this message translates to:
  /// **'● LIVE'**
  String get scheduleLive;

  /// No description provided for @scheduleSoon.
  ///
  /// In en, this message translates to:
  /// **'Soon'**
  String get scheduleSoon;

  /// No description provided for @scheduleInHours.
  ///
  /// In en, this message translates to:
  /// **'in {hours}h'**
  String scheduleInHours(int hours);

  /// No description provided for @scheduleInDays.
  ///
  /// In en, this message translates to:
  /// **'in {days}d'**
  String scheduleInDays(int days);

  /// No description provided for @scheduleCountDot.
  ///
  /// In en, this message translates to:
  /// **'· {count} {noun}'**
  String scheduleCountDot(int count, String noun);

  /// No description provided for @scheduleNounAiring.
  ///
  /// In en, this message translates to:
  /// **'airing'**
  String get scheduleNounAiring;

  /// No description provided for @scheduleNounReleasing.
  ///
  /// In en, this message translates to:
  /// **'releasing'**
  String get scheduleNounReleasing;

  /// No description provided for @seriesWithDate.
  ///
  /// In en, this message translates to:
  /// **'Series · {date}'**
  String seriesWithDate(String date);

  /// No description provided for @movieWithDate.
  ///
  /// In en, this message translates to:
  /// **'Movie · {date}'**
  String movieWithDate(String date);

  /// No description provided for @todayWithDate.
  ///
  /// In en, this message translates to:
  /// **'Today, {date}'**
  String todayWithDate(String date);

  /// No description provided for @extensionCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 extension} other{{count} extensions}}'**
  String extensionCount(int count);

  /// No description provided for @pasteRepoBaseUrlMihon.
  ///
  /// In en, this message translates to:
  /// **'Paste the repo\'s base URL — the app finds its index file itself. A link straight to index.pb or index.json works too.'**
  String get pasteRepoBaseUrlMihon;

  /// No description provided for @pasteRepoBaseUrlAniyomi.
  ///
  /// In en, this message translates to:
  /// **'Paste the repo\'s base URL — the app appends \"/index.min.json\" automatically.'**
  String get pasteRepoBaseUrlAniyomi;

  /// No description provided for @pasteRepoBaseUrlAniyomiTv.
  ///
  /// In en, this message translates to:
  /// **'Paste the repo base URL — the app appends \"/index.min.json\" automatically.'**
  String get pasteRepoBaseUrlAniyomiTv;

  /// No description provided for @pasteRepoIndexJsonUrl.
  ///
  /// In en, this message translates to:
  /// **'Paste the repo\'s index.json URL — the JSON file that lists every source in the repo, not a single provider .js URL.'**
  String get pasteRepoIndexJsonUrl;

  /// No description provided for @pasteRepoIndexJsonUrlShort.
  ///
  /// In en, this message translates to:
  /// **'Paste the repo\'s index.json URL.'**
  String get pasteRepoIndexJsonUrlShort;

  /// No description provided for @pasteCloudStreamRepoUrlFull.
  ///
  /// In en, this message translates to:
  /// **'Paste a CloudStream repository URL — the app loads every source it lists.'**
  String get pasteCloudStreamRepoUrlFull;

  /// No description provided for @youCanAddRepoBackLater.
  ///
  /// In en, this message translates to:
  /// **'You can add the repo back later.'**
  String get youCanAddRepoBackLater;

  /// No description provided for @failedToLoad.
  ///
  /// In en, this message translates to:
  /// **'Failed to load'**
  String get failedToLoad;

  /// No description provided for @failedToLoadError.
  ///
  /// In en, this message translates to:
  /// **'Failed to load: {error}'**
  String failedToLoadError(String error);

  /// No description provided for @noSourceLoaded.
  ///
  /// In en, this message translates to:
  /// **'No source loaded — the extension may be incompatible or the download failed.'**
  String get noSourceLoaded;

  /// No description provided for @repoAdded.
  ///
  /// In en, this message translates to:
  /// **'Repo added.'**
  String get repoAdded;

  /// No description provided for @repoAddedWithSources.
  ///
  /// In en, this message translates to:
  /// **'Repo added — {count} {count, plural, one{source} other{sources}}'**
  String repoAddedWithSources(int count);

  /// No description provided for @repoAddedWithSourcesAvailable.
  ///
  /// In en, this message translates to:
  /// **'Repo added — {count} {count, plural, one{source} other{sources}} available. Install the ones you want.'**
  String repoAddedWithSourcesAvailable(int count);

  /// No description provided for @upToDate.
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get upToDate;

  /// No description provided for @updatedNSources.
  ///
  /// In en, this message translates to:
  /// **'Updated {count} source(s)'**
  String updatedNSources(int count);

  /// No description provided for @enterManifestUrl.
  ///
  /// In en, this message translates to:
  /// **'Enter a manifest URL.'**
  String get enterManifestUrl;

  /// No description provided for @approve.
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get approve;

  /// No description provided for @changePhoto.
  ///
  /// In en, this message translates to:
  /// **'Change photo'**
  String get changePhoto;

  /// No description provided for @typingIsAPain.
  ///
  /// In en, this message translates to:
  /// **'Typing is a pain?'**
  String get typingIsAPain;

  /// No description provided for @dontHaveAnAccount.
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account?'**
  String get dontHaveAnAccount;

  /// No description provided for @signUp.
  ///
  /// In en, this message translates to:
  /// **'Sign up'**
  String get signUp;

  /// No description provided for @resetLinkSent.
  ///
  /// In en, this message translates to:
  /// **'Reset link sent — check your email (and spam).'**
  String get resetLinkSent;

  /// No description provided for @codeExpired.
  ///
  /// In en, this message translates to:
  /// **'Code expired'**
  String get codeExpired;

  /// No description provided for @somethingWentWrong.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get somethingWentWrong;

  /// No description provided for @pairingCodeTimedOut.
  ///
  /// In en, this message translates to:
  /// **'The pairing code timed out. Get a new one.'**
  String get pairingCodeTimedOut;

  /// No description provided for @couldntStartPairing.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t start pairing — check your connection.'**
  String get couldntStartPairing;

  /// No description provided for @approvalFailed.
  ///
  /// In en, this message translates to:
  /// **'Approval failed. Try again.'**
  String get approvalFailed;

  /// No description provided for @pickAtLeastOneTracker.
  ///
  /// In en, this message translates to:
  /// **'Pick at least one connected tracker.'**
  String get pickAtLeastOneTracker;

  /// No description provided for @sendFailedTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Send failed. Try again.'**
  String get sendFailedTryAgain;

  /// No description provided for @signUpFailed.
  ///
  /// In en, this message translates to:
  /// **'Sign up failed'**
  String get signUpFailed;

  /// No description provided for @invalidEmailOrPassword.
  ///
  /// In en, this message translates to:
  /// **'Invalid email or password'**
  String get invalidEmailOrPassword;

  /// No description provided for @authenticationFailed.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed'**
  String get authenticationFailed;

  /// No description provided for @couldNotReconnect.
  ///
  /// In en, this message translates to:
  /// **'Could not reconnect'**
  String get couldNotReconnect;

  /// No description provided for @couldntUpdatePhoto.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t update photo'**
  String get couldntUpdatePhoto;

  /// No description provided for @welcomeToApp.
  ///
  /// In en, this message translates to:
  /// **'Welcome to {appName}'**
  String welcomeToApp(String appName);

  /// No description provided for @onboardingTvSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{appName} comes with no sources built in — you add your own. Add a repository and pick what to install, any time from Settings → Providers.'**
  String onboardingTvSubtitle(String appName);

  /// No description provided for @onboardingPickEcosystem.
  ///
  /// In en, this message translates to:
  /// **'Pick an ecosystem — Streaming, Manga or Novel'**
  String get onboardingPickEcosystem;

  /// No description provided for @onboardingAddRepository.
  ///
  /// In en, this message translates to:
  /// **'Add a repository by pasting its URL'**
  String get onboardingAddRepository;

  /// No description provided for @onboardingBrowseAndInstall.
  ///
  /// In en, this message translates to:
  /// **'Browse it and install what you want'**
  String get onboardingBrowseAndInstall;

  /// No description provided for @providersWaitingInSettings.
  ///
  /// In en, this message translates to:
  /// **'Add a source now, or have a look around first — Providers is always waiting in Settings.'**
  String get providersWaitingInSettings;

  /// No description provided for @bufferSizeLow.
  ///
  /// In en, this message translates to:
  /// **'Low (32 MB) — low-RAM / TV'**
  String get bufferSizeLow;

  /// No description provided for @bufferSizeDefault.
  ///
  /// In en, this message translates to:
  /// **'Default (128 MB)'**
  String get bufferSizeDefault;

  /// No description provided for @bufferSizeHigh.
  ///
  /// In en, this message translates to:
  /// **'High (512 MB) — smoother'**
  String get bufferSizeHigh;

  /// No description provided for @bufferLengthLow.
  ///
  /// In en, this message translates to:
  /// **'Low (15s) — low-RAM / TV'**
  String get bufferLengthLow;

  /// No description provided for @bufferLengthDefault.
  ///
  /// In en, this message translates to:
  /// **'Default (60s)'**
  String get bufferLengthDefault;

  /// No description provided for @bufferLengthHigh.
  ///
  /// In en, this message translates to:
  /// **'High (120s) — smoother'**
  String get bufferLengthHigh;

  /// No description provided for @bufferLengthMax.
  ///
  /// In en, this message translates to:
  /// **'Max (300s) — longest'**
  String get bufferLengthMax;

  /// No description provided for @nUpdatesAvailable.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 update available} other{{count} updates available}}'**
  String nUpdatesAvailable(int count);

  /// No description provided for @languageCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 language} other{{count} languages}}'**
  String languageCount(int count);

  /// No description provided for @noExtensionsMatchQuery.
  ///
  /// In en, this message translates to:
  /// **'No extensions match \"{query}\".'**
  String noExtensionsMatchQuery(String query);

  /// No description provided for @noCloudStreamReposAddedYetTap.
  ///
  /// In en, this message translates to:
  /// **'No CloudStream repos added yet.\nTap {add} to add one.'**
  String noCloudStreamReposAddedYetTap(String add);

  /// No description provided for @noCloudStreamReposAddedYetPress.
  ///
  /// In en, this message translates to:
  /// **'No CloudStream repos added yet.\nPress {add} to add one.'**
  String noCloudStreamReposAddedYetPress(String add);

  /// No description provided for @noProvidersMatchQuery.
  ///
  /// In en, this message translates to:
  /// **'No providers match \"{query}\".'**
  String noProvidersMatchQuery(String query);

  /// No description provided for @noInstalledProvidersMatchQuery.
  ///
  /// In en, this message translates to:
  /// **'No installed providers match \"{query}\".'**
  String noInstalledProvidersMatchQuery(String query);

  /// No description provided for @noReposAddedYetTap.
  ///
  /// In en, this message translates to:
  /// **'No repos added yet.\nTap {add} to add one.'**
  String noReposAddedYetTap(String add);

  /// No description provided for @noReposAddedYetPress.
  ///
  /// In en, this message translates to:
  /// **'No repos added yet.\nPress {add} to add one.'**
  String noReposAddedYetPress(String add);

  /// No description provided for @showingEveryInstalledProvider.
  ///
  /// In en, this message translates to:
  /// **'Showing every installed provider'**
  String get showingEveryInstalledProvider;

  /// No description provided for @showingMangaNovelProviders.
  ///
  /// In en, this message translates to:
  /// **'Showing manga & novel providers'**
  String get showingMangaNovelProviders;

  /// No description provided for @mangaNovelOnly.
  ///
  /// In en, this message translates to:
  /// **'Manga & Novel only'**
  String get mangaNovelOnly;

  /// No description provided for @showAllProviders.
  ///
  /// In en, this message translates to:
  /// **'Show all'**
  String get showAllProviders;

  /// No description provided for @noMangaNovelProvidersInstalled.
  ///
  /// In en, this message translates to:
  /// **'No manga/novel providers installed.'**
  String get noMangaNovelProvidersInstalled;

  /// No description provided for @alreadyInstalledSourcesFromRepoStay.
  ///
  /// In en, this message translates to:
  /// **'Already-installed sources from \"{name}\" stay installed. '**
  String alreadyInstalledSourcesFromRepoStay(String name);

  /// No description provided for @pluginIndexPasteHelp.
  ///
  /// In en, this message translates to:
  /// **'Paste the URL of a plugin index — a JSON array of plugin entries (id, name, site, lang, version, url, iconUrl).'**
  String get pluginIndexPasteHelp;

  /// No description provided for @loadingTrailer.
  ///
  /// In en, this message translates to:
  /// **'Loading trailer…'**
  String get loadingTrailer;

  /// No description provided for @trailerUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Trailer unavailable'**
  String get trailerUnavailable;

  /// No description provided for @decoderHardwareRecommended.
  ///
  /// In en, this message translates to:
  /// **'Hardware+ (recommended)'**
  String get decoderHardwareRecommended;

  /// No description provided for @decoderHardwareFaster.
  ///
  /// In en, this message translates to:
  /// **'Hardware (faster)'**
  String get decoderHardwareFaster;

  /// No description provided for @decoderSoftwareCompatible.
  ///
  /// In en, this message translates to:
  /// **'Software (most compatible)'**
  String get decoderSoftwareCompatible;

  /// No description provided for @decoderAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get decoderAuto;

  /// No description provided for @rendererAutoRecommended.
  ///
  /// In en, this message translates to:
  /// **'Auto (recommended)'**
  String get rendererAutoRecommended;

  /// No description provided for @rendererGpuStandard.
  ///
  /// In en, this message translates to:
  /// **'GPU — standard renderer'**
  String get rendererGpuStandard;

  /// No description provided for @rendererGpuNextExperimental.
  ///
  /// In en, this message translates to:
  /// **'GPU Next — Vulkan, experimental'**
  String get rendererGpuNextExperimental;

  /// No description provided for @rendererMediacodecEmbed.
  ///
  /// In en, this message translates to:
  /// **'MediaCodec Embed — fixes black video'**
  String get rendererMediacodecEmbed;

  /// No description provided for @shaderStyleSharpenClean.
  ///
  /// In en, this message translates to:
  /// **'Sharpen — clean 1080p sources'**
  String get shaderStyleSharpenClean;

  /// No description provided for @shaderStyleDeblurSoft.
  ///
  /// In en, this message translates to:
  /// **'De-blur — blurry / soft sources'**
  String get shaderStyleDeblurSoft;

  /// No description provided for @shaderStyleDenoiseGrainy.
  ///
  /// In en, this message translates to:
  /// **'Denoise — grainy / compressed'**
  String get shaderStyleDenoiseGrainy;

  /// No description provided for @shaderTierMidLight.
  ///
  /// In en, this message translates to:
  /// **'Mid-range GPU — light, smooth'**
  String get shaderTierMidLight;

  /// No description provided for @shaderTierHighHeavy.
  ///
  /// In en, this message translates to:
  /// **'High-end GPU — heavier, sharpest'**
  String get shaderTierHighHeavy;

  /// No description provided for @closeConfirmDoubleBackLabel.
  ///
  /// In en, this message translates to:
  /// **'Double back — press back twice to exit'**
  String get closeConfirmDoubleBackLabel;

  /// No description provided for @closeConfirmAskLabel.
  ///
  /// In en, this message translates to:
  /// **'Close confirmation — ask before leaving'**
  String get closeConfirmAskLabel;

  /// No description provided for @closeConfirmExitImmediatelyLabel.
  ///
  /// In en, this message translates to:
  /// **'Close directly — exit immediately'**
  String get closeConfirmExitImmediatelyLabel;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'de',
    'en',
    'es',
    'fr',
    'it',
    'ja',
    'zh',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.countryCode) {
          case 'TW':
            return AppLocalizationsZhTw();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fr':
      return AppLocalizationsFr();
    case 'it':
      return AppLocalizationsIt();
    case 'ja':
      return AppLocalizationsJa();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
