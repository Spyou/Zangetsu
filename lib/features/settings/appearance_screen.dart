import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/theme/theme_controller.dart';

/// Dedicated Appearance page (Aniyomi-style): accent colour as preview cards
/// (+ a Custom colour picker), a pure-black AMOLED toggle, and the Home banner
/// animation style. Every option defaults to the current look, so an untouched
/// install is unchanged.
class AppearanceScreen extends StatefulWidget {
  const AppearanceScreen({super.key});

  @override
  State<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends State<AppearanceScreen> {
  bool get _accentIsCustom => !ThemeController.accentPresets
      .any((p) => p.$2.toARGB32() == AppColors.accent.toARGB32());

  Future<void> _pickCustom() async {
    var temp = AppColors.accent;
    final result = await showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Custom colour', style: AppText.headline),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: temp,
            onColorChanged: (c) => temp = c,
            enableAlpha: false,
            displayThumbColor: true,
            paletteType: PaletteType.hueWheel,
            labelTypes: const [],
            pickerAreaBorderRadius: BorderRadius.circular(12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, temp),
            child: Text('Apply', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (result != null) {
      await ThemeController.setAccent(result);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final presets = ThemeController.accentPresets;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text('Appearance', style: AppText.title),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          // ── Theme colour ──────────────────────────────────────────────────
          _label('THEME COLOUR'),
          const SizedBox(height: 6),
          Text(
            'The highlight colour used across buttons, chips, progress and '
            'selected items.',
            style: AppText.caption,
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 100,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              clipBehavior: Clip.none,
              itemCount: presets.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                if (i == presets.length) {
                  return _CustomCard(
                    selected: _accentIsCustom,
                    currentColor: AppColors.accent,
                    onTap: _pickCustom,
                  );
                }
                final (name, color) = presets[i];
                return _AccentCard(
                  name: name,
                  color: color,
                  selected: !_accentIsCustom &&
                      AppColors.accent.toARGB32() == color.toARGB32(),
                  isDefault: ThemeController.isDefault(color),
                  onTap: () async {
                    await ThemeController.setAccent(color);
                    if (mounted) setState(() {});
                  },
                );
              },
            ),
          ),

          const SizedBox(height: 28),
          // ── Background ────────────────────────────────────────────────────
          _label('BACKGROUND'),
          const SizedBox(height: 12),
          _amoledTile(),
        ],
      ),
    );
  }

  Widget _label(String text) => Text(text, style: AppText.overline);

  Widget _amoledTile() {
    final on = ThemeController.amoled;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          const Icon(Icons.dark_mode_outlined, color: AppColors.textSecondary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pure black background', style: AppText.headline),
                const SizedBox(height: 2),
                Text(
                  'True-black for OLED screens — deeper look, saves battery.',
                  style: AppText.caption,
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: on,
            activeThumbColor: AppColors.accent,
            onChanged: (v) async {
              await ThemeController.setAmoled(v);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }

}

/// A single accent option, rendered as a mini app preview in that colour.
class _AccentCard extends StatelessWidget {
  const _AccentCard({
    required this.name,
    required this.color,
    required this.selected,
    required this.isDefault,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final bool isDefault;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 98,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? color : AppColors.hairline,
              width: selected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: 58, child: _preview(color, selected)),
              const SizedBox(height: 8),
              Text(
                isDefault ? 'Default' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color:
                      selected ? AppColors.textPrimary : AppColors.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Custom" option — opens a colour wheel. Preview shows a rainbow sweep,
/// or the current custom colour when one is active.
class _CustomCard extends StatelessWidget {
  const _CustomCard({
    required this.selected,
    required this.currentColor,
    required this.onTap,
  });
  final bool selected;
  final Color currentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 98,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? currentColor : AppColors.hairline,
              width: selected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 58,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: const SweepGradient(
                      colors: [
                        Color(0xFFFF4D57),
                        Color(0xFFFFB020),
                        Color(0xFF32D583),
                        Color(0xFF3DD6D0),
                        Color(0xFF4D8DFF),
                        Color(0xFF9B6DFF),
                        Color(0xFFFF5FA2),
                        Color(0xFFFF4D57),
                      ],
                    ),
                  ),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        selected ? Icons.check_rounded : Icons.colorize_rounded,
                        color: AppColors.textPrimary,
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Custom',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color:
                      selected ? AppColors.textPrimary : AppColors.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _preview(Color color, bool selected) => Stack(
      children: [
        Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.all(9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Container(
                height: 5,
                width: 34,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 13,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: 13,
                    height: 13,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.22),
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              Container(
                height: 4,
                width: 58,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ],
          ),
        ),
        if (selected)
          Positioned(
            top: 3,
            right: 3,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.surface2, width: 2),
              ),
              child: const Icon(Icons.check_rounded, color: Colors.white, size: 11),
            ),
          ),
      ],
    );
