import 'media_item.dart';

/// One named row on the Home screen, CloudStream-style: the provider decides
/// what sections exist and what they are called (e.g. "Trending Now",
/// "Action & Adventure"), and the UI renders whatever it returns. A provider
/// that returns no sections (or has no `getHome`) falls back to a default set
/// built from `popular()` — see [SourceRepository.home].
class HomeSection {
  const HomeSection({required this.title, required this.items});

  final String title;
  final List<MediaItem> items;
}
