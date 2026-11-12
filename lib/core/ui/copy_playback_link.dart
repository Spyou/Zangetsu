import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_toast.dart';

Future<void> copyPlaybackLink(BuildContext context, String url) async {
  if (url.isEmpty) return;
  try {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) showAppToast(context, 'Link copied');
  } on PlatformException {
    if (context.mounted) showAppToast(context, 'Could not copy link');
  }
}
