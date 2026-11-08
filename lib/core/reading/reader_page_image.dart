import 'package:flutter/widgets.dart';

/// Retains a displayed page while the same page resolves at a new zoom size.
class ReaderPageImage extends StatefulWidget {
  const ReaderPageImage({
    super.key,
    required this.pageUrl,
    required this.image,
    required this.fit,
    required this.placeholderBuilder,
    required this.errorBuilder,
    required this.onLoaded,
    this.width,
  });

  final String pageUrl;
  final ImageProvider image;
  final BoxFit fit;
  final double? width;
  final Widget Function(BuildContext, double?) placeholderBuilder;
  final ImageErrorWidgetBuilder errorBuilder;
  final VoidCallback onLoaded;

  @override
  State<ReaderPageImage> createState() => _ReaderPageImageState();
}

class _ReaderPageImageState extends State<ReaderPageImage> {
  bool _hasFrame = false;

  @override
  void didUpdateWidget(ReaderPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageUrl != widget.pageUrl) _hasFrame = false;
  }

  @override
  Widget build(BuildContext context) => Image(
    key: ValueKey(widget.pageUrl),
    image: widget.image,
    width: widget.width,
    fit: widget.fit,
    gaplessPlayback: true,
    frameBuilder: (context, child, frame, wasSync) {
      if (frame != null) {
        _hasFrame = true;
        widget.onLoaded();
      }
      return _hasFrame ? child : widget.placeholderBuilder(context, null);
    },
    loadingBuilder: (context, child, progress) {
      if (_hasFrame || progress == null) return child;
      final total = progress.expectedTotalBytes;
      return widget.placeholderBuilder(
        context,
        total != null && total > 0
            ? progress.cumulativeBytesLoaded / total
            : null,
      );
    },
    errorBuilder: widget.errorBuilder,
  );
}
