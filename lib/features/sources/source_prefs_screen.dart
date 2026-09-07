import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/source_pref.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/app_toast.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/tv/tv_text_field.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';

/// An Aniyomi/Mihon source's own settings, drawn by us.
///
/// These used to open the extension's native preference screen, which lands in
/// its own task (a second card in recents) and is themed by Android rather than
/// by the app. The settings themselves are just typed data — see
/// `SourcePrefsCodec` on the native side — so nothing is lost by drawing them
/// here, and everything about them now matches the rest of the app.
///
/// [prefs] is read before this screen is pushed. Rows of a kind we cannot draw
/// are left out here and reached through [onOpenNative] instead, so an odd
/// setting is never invisible AND unreachable. [write] applies one change
/// through the source's own change listener and answers whether it stuck.
class SourcePrefsScreen extends StatefulWidget {
  const SourcePrefsScreen({
    super.key,
    required this.title,
    required this.prefs,
    required this.write,
    this.onOpenNative,
  });

  final String title;
  final List<SourcePref> prefs;
  final Future<bool> Function(String key, Object? value) write;

  /// Opens the extension's own screen. Set only when [prefs] holds a kind this
  /// screen cannot draw; null when there is nothing left over to go there for.
  final Future<void> Function()? onOpenNative;

  @override
  State<SourcePrefsScreen> createState() => _SourcePrefsScreenState();
}

class _SourcePrefsScreenState extends State<SourcePrefsScreen> {
  // Undrawable rows never reach the list; they are what [onOpenNative] is for.
  late List<SourcePref> _prefs = widget.prefs.where((p) => p.drawable).toList();

  /// Apply [value] to the pref at [i], keeping the screen honest: the row only
  /// moves once the source has accepted the change. A source that refuses (its
  /// listener returns false) would otherwise leave a switch showing a state it
  /// never took.
  Future<void> _set(int i, Object? value) async {
    final p = _prefs[i];
    final ok = await widget.write(p.key, value);
    if (!mounted) return;
    if (!ok) {
      showAppToast(context, context.l10n.somethingWentWrong);
      return;
    }
    setState(() {
      _prefs = [..._prefs]..[i] = SourcePref(
        key: p.key,
        type: p.type,
        title: p.title,
        summary: p.summary,
        value: value,
        entries: p.entries,
        values: p.values,
      );
    });
  }

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  /// The TV shell for a chooser. A Material sheet's focus paints behind opaque
  /// rows and is invisible at ten feet, and its list tiles take no D-pad focus
  /// at all — on TV the picker opened and then could not be used. Same shape
  /// the Playback settings picker uses.
  Future<T?> _tvChooser<T>({
    required String title,
    required List<Widget> Function(BuildContext ctx) children,
  }) => showDialog<T>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
      child: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Text(title, style: AppText.title),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.6,
                ),
                child: ListView(
                  shrinkWrap: true,
                  clipBehavior: Clip.none,
                  padding: const EdgeInsets.only(bottom: 12),
                  children: children(ctx),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _tvRow(
    String label, {
    required VoidCallback onTap,
    bool selected = false,
    bool autofocus = false,
  }) => TvListFocusable(
    autofocus: autofocus,
    semanticLabel: label,
    onTap: onTap,
    child: ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AppText.headline)),
            if (selected)
              Icon(Icons.check, color: AppColors.accent, size: 20),
          ],
        ),
      ),
    ),
  );

  Future<void> _pickOne(int i) async {
    final p = _prefs[i];
    if (_isTv) {
      final picked = await _tvChooser<String>(
        title: p.title,
        children: (ctx) => [
          for (var j = 0; j < p.entries.length; j++)
            _tvRow(
              p.entries[j],
              selected: p.values[j] == p.asText,
              autofocus: p.values[j] == p.asText,
              onTap: () => Navigator.pop(ctx, p.values[j]),
            ),
        ],
      );
      if (picked != null) await _set(i, picked);
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _Sheet(
        title: p.title,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 8),
          children: [
            for (var j = 0; j < p.entries.length; j++)
              ListTile(
                onTap: () => Navigator.pop(ctx, p.values[j]),
                title: Text(
                  p.entries[j],
                  style: AppText.body.copyWith(color: AppColors.textPrimary),
                ),
                trailing: p.values[j] == p.asText
                    ? Icon(Icons.check, color: AppColors.accent)
                    : null,
              ),
          ],
        ),
      ),
    );
    if (picked != null) await _set(i, picked);
  }

  Future<void> _pickMany(int i) async {
    final p = _prefs[i];
    final chosen = {...p.asList};
    if (_isTv) {
      final saved = await _tvChooser<bool>(
        title: p.title,
        children: (ctx) => [
          StatefulBuilder(
            builder: (ctx2, setInner) => Column(
              children: [
                for (var j = 0; j < p.entries.length; j++)
                  _tvRow(
                    p.entries[j],
                    selected: chosen.contains(p.values[j]),
                    autofocus: j == 0,
                    onTap: () => setInner(() {
                      chosen.contains(p.values[j])
                          ? chosen.remove(p.values[j])
                          : chosen.add(p.values[j]);
                    }),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.hairline),
          _tvRow(context.l10n.save, onTap: () => Navigator.pop(ctx, true)),
        ],
      );
      if (saved == true) await _set(i, chosen.toList());
      return;
    }
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => _Sheet(
          title: p.title,
          // Applied on Save, not per tap: a multi-select writes the whole set,
          // so per-tap writes would fire the source's listener once per box.
          action: TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.l10n.save),
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              for (var j = 0; j < p.entries.length; j++)
                CheckboxListTile(
                  value: chosen.contains(p.values[j]),
                  onChanged: (v) => setSheet(() {
                    v == true
                        ? chosen.add(p.values[j])
                        : chosen.remove(p.values[j]);
                  }),
                  activeColor: AppColors.accent,
                  title: Text(
                    p.entries[j],
                    style: AppText.body.copyWith(color: AppColors.textPrimary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (saved == true) await _set(i, chosen.toList());
  }

  Future<void> _editText(int i) async {
    final p = _prefs[i];
    final controller = TextEditingController(text: p.asText);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(p.title, style: AppText.headline),
        // TvTextField on TV: a bare TextField raises the leanback IME, which
        // swallows the D-pad so the remote can never reach Cancel or Save.
        content: _isTv
            ? TvTextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(hintText: p.summary),
              )
            : TextField(
                controller: controller,
                autofocus: true,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                decoration: InputDecoration(hintText: p.summary),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );
    if (saved == true) await _set(i, controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(widget.title, style: AppText.headline),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          SettingsCard(
            children: [
              for (var i = 0; i < _prefs.length; i++) _row(i),
            ],
          ),
          if (widget.onOpenNative != null) ...[
            SettingsSectionLabel(context.l10n.otherSettings),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.open_in_new_rounded,
                  title: context.l10n.otherSettings,
                  subtitle: context.l10n.otherSettingsSubtitle,
                  subtitleMaxLines: null,
                  onTap: () => widget.onOpenNative!(),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(int i) {
    final p = _prefs[i];
    // A source's summary is often the whole explanation, so let it wrap rather
    // than cutting it at one line the way a normal settings row does.
    switch (p.type) {
      case SourcePrefType.switchToggle:
      case SourcePrefType.checkbox:
        return SettingsTile(
          icon: Icons.tune_rounded,
          title: p.title,
          subtitle: p.summary.isEmpty ? null : p.summary,
          subtitleMaxLines: null,
          autofocus: i == 0,
          trailing: Switch.adaptive(
            value: p.asBool,
            activeThumbColor: AppColors.accent,
            onChanged: (v) => _set(i, v),
          ),
          onTap: () => _set(i, !p.asBool),
        );
      case SourcePrefType.list:
        return SettingsTile(
          icon: Icons.list_rounded,
          title: p.title,
          subtitle: p.selectedEntry.isNotEmpty
              ? p.selectedEntry
              : (p.summary.isEmpty ? null : p.summary),
          autofocus: i == 0,
          onTap: () => _pickOne(i),
        );
      case SourcePrefType.multi:
        return SettingsTile(
          icon: Icons.checklist_rounded,
          title: p.title,
          subtitle: p.asList.isEmpty
              ? (p.summary.isEmpty ? null : p.summary)
              : p.asList.length.toString(),
          autofocus: i == 0,
          onTap: () => _pickMany(i),
        );
      case SourcePrefType.text:
        return SettingsTile(
          icon: Icons.edit_rounded,
          title: p.title,
          subtitle: p.asText.isEmpty
              ? (p.summary.isEmpty ? null : p.summary)
              : p.asText,
          autofocus: i == 0,
          onTap: () => _editText(i),
        );
      // Filtered out of [_prefs] above; the switch stays exhaustive so a new
      // kind added later is a compile error rather than a blank row.
      case SourcePrefType.unknown:
        return const SizedBox.shrink();
    }
  }
}

/// The bottom-sheet chrome both pickers share.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.title, required this.child, this.action});

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => SafeArea(
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
          padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
          child: Row(
            children: [
              Expanded(child: Text(title, style: AppText.headline)),
              ?action,
            ],
          ),
        ),
        const Divider(color: AppColors.hairline, height: 1),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6,
            ),
            child: child,
          ),
        ),
      ],
    ),
  );
}
