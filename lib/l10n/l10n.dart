import 'package:flutter/widgets.dart';

import 'app_localizations.dart';
import 'app_localizations_en.dart';

export 'app_localizations.dart';

/// English, built once, for contexts with no [Localizations] above them.
final _fallback = AppLocalizationsEn();

extension L10nX on BuildContext {
  /// The current translations, falling back to English rather than throwing.
  ///
  /// `l10n.yaml` sets `nullable-getter: false`, so the generated
  /// `AppLocalizations.of` ends in `!` and dies on any context without the
  /// delegates above it. That's every widget test that pumps a bare
  /// `MaterialApp`, and it would be a crash in the app too if a delegate ever
  /// went missing from a route. English is a far better answer than a
  /// `Null check operator used on a null value`.
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ?? _fallback;
}
