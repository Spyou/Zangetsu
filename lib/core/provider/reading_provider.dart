import '../models/page_content.dart';

/// Reading counterpart of [BaseProvider]'s video leaf. A source that serves
/// manga or novels implements this alongside `BaseProvider` to supply
/// [PageImage]s / [ChapterText] for a chapter URL.
///
/// Kept out of `BaseProvider` itself: `BaseProvider`'s conformers all use
/// `implements`, which requires a real body for every member — folding these
/// in there would force CloudStream/Aniyomi (video-only, no JS-style default
/// bodies) to stub out methods they'll never use.
abstract class ReadingProvider {
  /// Manga leaf: ordered page images for a chapter.
  Future<List<PageImage>> getPages(String chapterUrl);

  /// Novel leaf: a chapter's text/HTML.
  Future<ChapterText> getText(String chapterUrl);
}
