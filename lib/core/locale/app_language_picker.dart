import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../tv/tv_list_focusable.dart';
import 'locale_controller.dart';

/// Trailing label for the App language settings row.
String appLanguageValueLabel(BuildContext context) {
  final l10n = context.l10n;
  final device = View.of(context).platformDispatcher.locale;
  if (LocaleController.followsSystem) {
    return l10n.appLanguageSystemSubtitle(
      LocaleController.nativeNameForDevice(device),
    );
  }
  return LocaleController.nativeNameFor(LocaleController.tag) ??
      LocaleController.tag;
}

/// Phone: bottom sheet with System (auto) + fixed locale list.
Future<void> pickAppLanguagePhone(BuildContext context) async {
  final l10n = context.l10n;
  final device = View.of(context).platformDispatcher.locale;
  final current = LocaleController.tag;

  final picked = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final systemSubtitle = l10n.appLanguageSystemSubtitle(
        LocaleController.nativeNameForDevice(device),
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textTertiary.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(l10n.appLanguage, style: AppText.headline),
              ),
            ),
            const Divider(color: AppColors.hairline, height: 1),
            ListTile(
              title: Text(l10n.appLanguageSystem, style: AppText.body),
              subtitle: Text(systemSubtitle, style: AppText.caption),
              trailing: current == LocaleController.systemTag
                  ? Icon(Icons.check_rounded, color: AppColors.accent)
                  : null,
              onTap: () => Navigator.pop(ctx, LocaleController.systemTag),
            ),
            for (final (tag, name) in LocaleController.options)
              ListTile(
                title: Text(name, style: AppText.body),
                trailing: tag == current
                    ? Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.pop(ctx, tag),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (picked == null || picked == current) return;
  await LocaleController.setTag(picked);
}

/// TV: D-pad dialog with the same options as [pickAppLanguagePhone].
Future<void> pickAppLanguageTv(BuildContext context) async {
  final l10n = context.l10n;
  final device = View.of(context).platformDispatcher.locale;
  final current = LocaleController.tag;
  final systemSubtitle = l10n.appLanguageSystemSubtitle(
    LocaleController.nativeNameForDevice(device),
  );

  final options = <(String, String)>[
    (LocaleController.systemTag, '${l10n.appLanguageSystem}\n$systemSubtitle'),
    ...LocaleController.options,
  ];

  final picked = await showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
      child: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Text(
                l10n.appLanguage,
                style: AppText.title.copyWith(color: AppColors.textPrimary),
              ),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            for (var i = 0; i < options.length; i++)
              TvListFocusable(
                autofocus: options[i].$1 == current,
                onTap: () => Navigator.of(ctx).pop(options[i].$1),
                semanticLabel: options[i].$2.split('\n').first,
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            options[i].$2,
                            style: AppText.headline,
                          ),
                        ),
                        if (options[i].$1 == current)
                          Icon(Icons.check, color: AppColors.accent, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
  if (picked == null || picked == current) return;
  await LocaleController.setTag(picked);
}
