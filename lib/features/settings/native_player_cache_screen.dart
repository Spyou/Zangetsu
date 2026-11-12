import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/di/injector.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';

class NativePlayerCacheScreen extends StatefulWidget {
  const NativePlayerCacheScreen({super.key});

  @override
  State<NativePlayerCacheScreen> createState() =>
      _NativePlayerCacheScreenState();
}

class _NativePlayerCacheScreenState extends State<NativePlayerCacheScreen> {
  static const _channel = MethodChannel('zangetsu/phone_player');
  PlaybackPrefs get _prefs => sl<PlaybackPrefs>();
  late double _nativeMb = _prefs.phoneNativeCacheMb.toDouble();
  late double _diskGb = _prefs.phoneDiskCacheGb.toDouble();
  int _nativeLimitMb = 0;
  int _diskBytes = 0;
  bool _loaded = false;
  bool _unavailable = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'cacheInfo',
        {'diskCacheGb': _prefs.phoneDiskCacheGb},
      );
      if (!mounted) return;
      setState(() {
        final limit = info?['nativeLimitMb'];
        _nativeLimitMb = limit is num ? limit.toInt().clamp(0, 512) : 0;
        final bytes = info?['diskBytes'];
        _diskBytes = bytes is num ? bytes.toInt().clamp(0, 1 << 50) : 0;
        _unavailable = info?['cacheError'] == true;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _unavailable = true);
    }
  }

  Future<void> _clear() async {
    setState(() => _clearing = true);
    try {
      final cleared = await _channel.invokeMethod<bool>('clearPlaybackCache', {
        'diskCacheGb': _prefs.phoneDiskCacheGb,
      });
      if (!mounted) return;
      if (cleared == true) {
        await _loadInfo();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.androidCacheClearBusy)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.androidCacheUnavailable)),
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Widget _valueBadge(String value, {bool enabled = true}) => Container(
    constraints: const BoxConstraints(minWidth: 72),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: enabled ? AppColors.accentSoft : AppColors.hairline,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      value,
      style: AppText.body.copyWith(
        color: enabled ? AppColors.accent : AppColors.textSecondary,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _sizeSlider({
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required String unit,
    required bool enabled,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${min.round()}–${max.round()} $unit',
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              _valueBadge(label, enabled: enabled),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.accent,
              thumbColor: AppColors.accent,
              inactiveTrackColor: AppColors.hairline,
              overlayColor: AppColors.accentSoft,
              trackHeight: 4,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              padding: const EdgeInsets.symmetric(vertical: 16),
              divisions: divisions,
              label: label,
              onChanged: enabled ? onChanged : null,
              onChangeEnd: enabled ? onChangeEnd : null,
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final nativeMb = _nativeMb.clamp(
      32.0,
      _nativeLimitMb >= 32 ? _nativeLimitMb.toDouble() : 32.0,
    );
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(l10n.androidPlayerCache),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          if (_loaded) ...[
            SettingsCard(
              children: [
                Column(
                  children: [
                    SettingsTile(
                      icon: Icons.memory_rounded,
                      title: l10n.androidNativeCache,
                      subtitle: _nativeLimitMb >= 32
                          ? l10n.androidNativeCacheDescription
                          : l10n.androidNativeCacheUnavailable,
                      subtitleMaxLines: null,
                      trailing: Switch(
                        activeThumbColor: AppColors.accent,
                        value: _prefs.phoneNativeCacheEnabled,
                        onChanged:
                            _nativeLimitMb < 32 &&
                                !_prefs.phoneNativeCacheEnabled
                            ? null
                            : (value) async {
                                await _prefs.setPhoneNativeCacheEnabled(value);
                                if (mounted) setState(() {});
                              },
                      ),
                    ),
                    if (_nativeLimitMb > 32)
                      _sizeSlider(
                        value: nativeMb,
                        min: 32,
                        max: _nativeLimitMb.toDouble(),
                        divisions: _nativeLimitMb ~/ 32 - 1,
                        label: '${nativeMb.round()} MB',
                        unit: 'MB',
                        enabled: _prefs.phoneNativeCacheEnabled,
                        onChanged: (value) => setState(() => _nativeMb = value),
                        onChangeEnd: (value) =>
                            _prefs.setPhoneNativeCacheMb(value.round()),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            SettingsCard(
              children: [
                Column(
                  children: [
                    SettingsTile(
                      icon: Icons.storage_rounded,
                      title: l10n.androidDiskCache,
                      subtitle: l10n.androidDiskCacheDescription,
                      subtitleMaxLines: null,
                      trailing: Switch(
                        activeThumbColor: AppColors.accent,
                        value: _prefs.phoneDiskCacheEnabled,
                        onChanged: (value) async {
                          await _prefs.setPhoneDiskCacheEnabled(value);
                          if (mounted) setState(() {});
                        },
                      ),
                    ),
                    _sizeSlider(
                      value: _diskGb,
                      min: 1,
                      max: 20,
                      divisions: 19,
                      label: '${_diskGb.round()} GB',
                      unit: 'GB',
                      enabled: _prefs.phoneDiskCacheEnabled,
                      onChanged: (value) => setState(() => _diskGb = value),
                      onChangeEnd: (value) =>
                          _prefs.setPhoneDiskCacheGb(value.round()),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.delete_outline_rounded,
                  title: l10n.androidCacheClear,
                  subtitle:
                      '${(_diskBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                  onTap: _clearing ? null : _clear,
                ),
              ],
            ),
          ],
          if (!_loaded && !_unavailable)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_unavailable)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Text(l10n.androidCacheUnavailable, style: AppText.caption),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: AppColors.textTertiary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.androidPlayerCacheNote,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
