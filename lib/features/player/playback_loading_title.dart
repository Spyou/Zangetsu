import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

Map<String, String>? playbackArtworkHeaders(
  String? artwork,
  String? cover,
  Map<String, String>? headers,
) {
  final image = Uri.tryParse(artwork ?? '');
  final original = Uri.tryParse(cover ?? '');
  if (image == null || original == null || image.host.isEmpty) return null;
  if (image.scheme != 'http' && image.scheme != 'https') return null;
  return image.scheme == original.scheme &&
          image.host == original.host &&
          image.port == original.port
      ? headers
      : null;
}

/// Startup screen content: big logo (or title text), slow pulse, soft fade-in,
/// and the status line underneath. One widget for every player path so mpv and
/// ExoPlayer look the same.
class PlaybackLoadingTitle extends StatelessWidget {
  const PlaybackLoadingTitle({
    super.key,
    required this.title,
    required this.status,
    this.logo,
    this.speed,
  });

  final String title;
  final String status;
  final String? logo;

  /// Reads the current download speed in bytes/s (null if unknown). Polled
  /// once a second; the line stays hidden while there's nothing to show.
  final Future<String?> Function()? speed;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // Sized from the box it sits in, so the small portrait video box doesn't
    // get a full-screen-sized logo.
    builder: (context, c) => _build(
      context,
      Size(
        c.maxWidth.isFinite ? c.maxWidth : MediaQuery.sizeOf(context).width,
        c.maxHeight.isFinite ? c.maxHeight : MediaQuery.sizeOf(context).height,
      ),
    ),
  );

  Widget _build(BuildContext context, Size size) {
    final logoUrl = logo?.trim() ?? '';
    final text = title.trim();
    final still = MediaQuery.disableAnimationsOf(context);
    Widget motion(Widget child) =>
        still ? child : _StartupTitlePulse(child: child);

    final titleText = Text(
      text,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Colors.white,
        fontSize: size.width < 600 ? (size.height < 300 ? 22 : 30) : 42,
        fontWeight: FontWeight.w800,
      ),
    );
    final textOrSpinner = text.isEmpty
        ? const SizedBox(
            width: 54,
            height: 54,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Colors.white,
            ),
          )
        : motion(titleText);

    final logoBox = SizedBox(
      width: math.min(320, size.width - 48),
      height: math.min(180, size.height * 0.4),
      child: CachedNetworkImage(
        key: ValueKey(logoUrl),
        imageUrl: logoUrl,
        fit: BoxFit.contain,
        memCacheWidth: 720,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        // Slot stays empty while it loads: no title text flashing first.
        placeholder: (_, _) => const SizedBox.shrink(),
        errorWidget: (_, _, _) => Center(child: textOrSpinner),
        imageBuilder: (_, provider) => motion(
          Image(image: provider, fit: BoxFit.contain, semanticLabel: title),
        ),
      ),
    );

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            logoUrl.isNotEmpty ? logoBox : textOrSpinner,
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              child: SizedBox(
                key: ValueKey(status),
                height: 40,
                child: Center(
                  child: Text(
                    status,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: const TextStyle(
                      color: Color(0xB8FFFFFF),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
            if (speed != null) _SpeedLine(read: speed!),
          ],
        ),
      ),
    );
  }
}

class _SpeedLine extends StatefulWidget {
  const _SpeedLine({required this.read});

  final Future<String?> Function() read;

  @override
  State<_SpeedLine> createState() => _SpeedLineState();
}

class _SpeedLineState extends State<_SpeedLine> {
  String? _text;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _poll());
  }

  bool _reading = false;

  Future<void> _poll() async {
    if (_reading) return;
    _reading = true;
    final bytes = double.tryParse(await widget.read() ?? '') ?? 0;
    _reading = false;
    final text = bytes <= 0
        ? null
        : bytes >= 1024 * 1024
        ? '${(bytes / 1048576).toStringAsFixed(1)} MB/s'
        : '${(bytes / 1024).round()} KB/s';
    if (mounted && text != _text) setState(() => _text = text);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    excluding: _text == null,
    child: AnimatedOpacity(
      opacity: _text == null ? 0 : 1,
      duration: const Duration(milliseconds: 200),
      child: Text(
        _text ?? '0 KB/s',
        style: const TextStyle(color: Color(0x8FFFFFFF), fontSize: 11),
      ),
    ),
  );
}

class _StartupTitlePulse extends StatefulWidget {
  const _StartupTitlePulse({required this.child});

  final Widget child;

  @override
  State<_StartupTitlePulse> createState() => _StartupTitlePulseState();
}

class _StartupTitlePulseState extends State<_StartupTitlePulse>
    with TickerProviderStateMixin {
  // Slow, even breathing: 1.0 -> 1.04 over 2s.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);
  // Fades in after a short beat so nothing pops on screen.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..forward();
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _fade,
    curve: const Interval(400 / 1100, 1),
  );

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: AnimatedBuilder(
        animation: _pulse,
        child: widget.child,
        builder: (context, child) => Transform.scale(
          key: const ValueKey('startup-title-motion'),
          scale: 1 + 0.04 * _pulse.value,
          child: child,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    _fade.dispose();
    super.dispose();
  }
}
