import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';

/// Shown when startup doesn't finish — either a boot step threw, or it hung
/// past the watchdog.
///
/// Before this existed the app simply kept the splash on screen forever: no
/// message, nothing to tap, and the only way out was reinstalling. This screen
/// exists so that state is recoverable and reportable instead of terminal.
///
/// Tone is deliberately calm. Someone reaching this is looking at an app that
/// won't open, so it leads with reassurance that their account and library are
/// safe, offers the harmless action first, and keeps the technical detail
/// folded away for anyone who wants to send it in.
class BootErrorScreen extends StatefulWidget {
  const BootErrorScreen({super.key, required this.details, this.onRetry});

  /// Exception + stack (or a timeout note) — shown only under "details".
  final String details;

  /// Re-runs startup. Null hides the button.
  final VoidCallback? onRetry;

  @override
  State<BootErrorScreen> createState() => _BootErrorScreenState();
}

class _BootErrorScreenState extends State<BootErrorScreen> {
  bool _showDetails = false;
  bool _resetting = false;

  /// Deletes the local Hive data and asks the user to reopen the app.
  ///
  /// Only ever reached from an explicit, confirmed tap. Nothing here touches
  /// the account or the cloud copy — signing back in restores the library.
  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(ctx.l10n.resetAppDataTitle, style: AppText.title),
        content: Text(
          ctx.l10n.resetAppDataBody,
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.reset, style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _resetting = true);
    try {
      await Hive.deleteFromDisk();
    } catch (_) {
      // Nothing useful left to do — the message below still tells them to
      // reopen the app, and a failed delete leaves them no worse off.
    }
    if (!mounted) return;
    setState(() => _resetting = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(ctx.l10n.done, style: AppText.title),
        content: Text(
          ctx.l10n.resetAppDataDone,
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.l10n.ok),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 32, 28, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.refresh_rounded,
                    size: 44,
                    color: AppColors.accent,
                  ),
                  const SizedBox(height: 18),
                  Text(context.l10n.bootErrorTitle,
                    style: AppText.headline,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    context.l10n.bootErrorBody,
                    style: AppText.body,
                  ),
                  const SizedBox(height: 24),
                  if (widget.onRetry != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _resetting ? null : widget.onRetry,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: Text(context.l10n.tryAgain),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _resetting ? null : _reset,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: AppColors.hairline),
                      ),
                      child: _resetting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(context.l10n.resetAppData),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Folded away: useful to us, noise to everyone else.
                  GestureDetector(
                    onTap: () => setState(() => _showDetails = !_showDetails),
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        Text(
                          _showDetails ? context.l10n.hideDetails : context.l10n.showDetails,
                          style: AppText.caption.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                        Icon(
                          _showDetails
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                          color: AppColors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                  if (_showDetails) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        widget.details,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.4,
                          fontFamily: 'monospace',
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: widget.details),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(context.l10n.detailsCopied),
                          ),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: Text(context.l10n.copyDetails),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
