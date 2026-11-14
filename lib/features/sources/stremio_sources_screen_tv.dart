part of 'stremio_sources_screen.dart';

ThemeData _stremioTvTheme(ThemeData theme) {
  ButtonStyle focusedButtons(ButtonStyle? style) {
    final original = style ?? const ButtonStyle();
    return original.copyWith(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.focused) &&
                !states.contains(WidgetState.disabled)
            ? Colors.white
            : original.backgroundColor?.resolve(states),
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.focused) &&
                !states.contains(WidgetState.disabled)
            ? Colors.black
            : original.foregroundColor?.resolve(states),
      ),
      side: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.focused) &&
                !states.contains(WidgetState.disabled)
            ? const BorderSide(color: Colors.white, width: 2)
            : original.side?.resolve(states),
      ),
    );
  }

  return theme.copyWith(
    focusColor: Colors.white.withValues(alpha: .2),
    iconButtonTheme: IconButtonThemeData(
      style: focusedButtons(theme.iconButtonTheme.style),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: focusedButtons(theme.filledButtonTheme.style),
    ),
    switchTheme: theme.switchTheme.copyWith(
      trackOutlineWidth: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? 2
            : theme.switchTheme.trackOutlineWidth?.resolve(states),
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? Colors.white
            : theme.switchTheme.trackOutlineColor?.resolve(states),
      ),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? Colors.white.withValues(alpha: .2)
            : theme.switchTheme.overlayColor?.resolve(states),
      ),
    ),
  );
}

Widget _stremioTvConfigureDialog(
  BuildContext dialog,
  TextEditingController controller,
  String name,
) => TvAlertDialog(
  title: 'Update $name',
  body: TvTextField(
    controller: controller,
    keyboardType: TextInputType.url,
    autocorrect: false,
    enableSuggestions: false,
    decoration: const InputDecoration(
      labelText: 'Configured addon URL',
      hintText: 'Paste the URL from the addon settings page',
    ),
  ),
  actions: [
    TvAlertAction(
      label: 'Cancel',
      autofocus: true,
      onTap: () => Navigator.of(dialog).pop(),
    ),
    TvAlertAction(
      label: 'Save',
      primary: true,
      onTap: () => Navigator.of(dialog).pop(controller.text),
    ),
  ],
);

Widget _stremioTvRemoveDialog(BuildContext dialog, String name) =>
    TvAlertDialog(
      title: 'Remove addon?',
      body: Text(name),
      actions: [
        TvAlertAction(
          label: 'Cancel',
          autofocus: true,
          onTap: () => Navigator.of(dialog).pop(false),
        ),
        TvAlertAction(
          label: 'Remove',
          primary: true,
          onTap: () => Navigator.of(dialog).pop(true),
        ),
      ],
    );
