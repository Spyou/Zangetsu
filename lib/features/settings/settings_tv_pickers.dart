part of 'settings_screen.dart';

/// D-pad option picker dialog (DNS / search layout / batch download / etc.).
class _TvOptionPicker<T> extends StatelessWidget {
  const _TvOptionPicker({
    super.key,
    required this.title,
    required this.options,
    required this.current,
  });

  final String title;
  final List<(T, String)> options;
  final T current;

  @override
  Widget build(BuildContext context) {
    return Dialog(
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
                title,
                style: AppText.title.copyWith(color: AppColors.textPrimary),
              ),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            for (int i = 0; i < options.length; i++)
              TvListFocusable(
                autofocus: options[i].$1 == current,
                onTap: () => Navigator.of(context).pop(options[i].$1),
                semanticLabel: options[i].$2,
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(options[i].$2, style: AppText.headline),
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
    );
  }
}

class _TvAddRepoDialog extends StatefulWidget {
  const _TvAddRepoDialog();

  @override
  State<_TvAddRepoDialog> createState() => _TvAddRepoDialogState();
}

class _TvAddRepoDialogState extends State<_TvAddRepoDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(
        context.l10n.addCloudStreamRepository,
        style: AppText.headline,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              keyboardType: TextInputType.url,
              cursorColor: AppColors.accent,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: context.l10n.repositoryUrlLabel,
                hintText: 'https://.../repo.json',
              ),
              onSubmitted: (v) => Navigator.pop(context, v.trim()),
            ),
          ],
        ),
      ),
      actions: [
        TvFocusable(
          variant: TvFocusVariant.pill,
          onTap: () => Navigator.pop(context),
          semanticLabel: context.l10n.cancel,
          builder: (focused) => ExcludeSemantics(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                context.l10n.cancel,
                style: AppText.body.copyWith(
                  color: focused ? Colors.black : AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
        TvFocusable(
          variant: TvFocusVariant.pill,
          onTap: () => Navigator.pop(context, _controller.text.trim()),
          semanticLabel: context.l10n.add,
          builder: (focused) => ExcludeSemantics(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: focused ? Colors.black : AppColors.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, _controller.text.trim()),
              child: Text(context.l10n.add),
            ),
          ),
        ),
      ],
    );
  }
}
