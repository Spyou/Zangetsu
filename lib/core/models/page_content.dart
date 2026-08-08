/// Leaf content for reading sources — the analogue of [VideoSource] for
/// manga (page images) and novels (chapter text).
class PageImage {
  const PageImage({required this.url, this.headers});

  final String url;
  final Map<String, String>? headers;

  static PageImage? fromJson(dynamic j) {
    if (j is! Map) return null;
    final url = j['url'];
    if (url is! String || url.isEmpty) return null;
    final h = j['headers'];
    return PageImage(
      url: url,
      headers: h is Map
          ? h.map((k, v) => MapEntry(k.toString(), v.toString()))
          : null,
    );
  }

  static List<PageImage> listFromJson(dynamic j) => j is! List
      ? const []
      : j.map(fromJson).whereType<PageImage>().toList();
}

class ChapterText {
  const ChapterText({required this.html, this.title});

  final String html;
  final String? title;

  factory ChapterText.fromJson(Map j) => ChapterText(
        html: (j['html'] ?? j['text'] ?? '').toString(),
        title: j['title']?.toString(),
      );
}
