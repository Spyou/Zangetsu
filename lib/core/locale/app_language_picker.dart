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
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.75,
    ),
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
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
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
                ],
              ),
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
    (LocaleController.systemTag, l10n.appLanguageSystem),
    ...LocaleController.options,
  ];

  final picked = await showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) {
      final maxHeight = MediaQuery.sizeOf(ctx).height - 96;
      // Title + divider + bottom inset — cap the scroll region explicitly so
      // ListView scrolls instead of expanding the dialog past the screen.
      const headerExtent = 80.0;
      return Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 400, maxHeight: maxHeight),
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
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: maxHeight - headerExtent,
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (var i = 0; i < options.length; i++)
                      TvListFocusable(
                        autofocus: options[i].$1 == current,
                        onTap: () => Navigator.of(ctx).pop(options[i].$1),
                        semanticLabel: options[i].$2,
                        child: ExcludeSemantics(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 14,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: options[i].$1 == LocaleController.systemTag
                                      ? Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              l10n.appLanguageSystem,
                                              style: AppText.headline,
                                            ),
                                            Text(
                                              systemSubtitle,
                                              style: AppText.caption,
                                            ),
                                          ],
                                        )
                                      : Text(
                                          options[i].$2,
                                          style: AppText.headline,
                                        ),
                                ),
                                if (options[i].$1 == current)
                                  Icon(
                                    Icons.check,
                                    color: AppColors.accent,
                                    size: 20,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
    },
  );
  if (picked == null || picked == current) return;
  await LocaleController.setTag(picked);
}
