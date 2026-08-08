import 'package:flutter/material.dart';
import '../models/provider_info.dart';

/// The app-wide content mode. Anime is the default and covers the whole
/// existing video app (anime + movie sources); manga/novel are reading modes.
enum ContentMode { anime, manga, novel }

extension ContentModeX on ContentMode {
  String get label => switch (this) {
    ContentMode.anime => 'Anime',
    ContentMode.manga => 'Manga',
    ContentMode.novel => 'Novel',
  };

  IconData get icon => switch (this) {
    ContentMode.anime => Icons.play_circle_outline_rounded,
    ContentMode.manga => Icons.auto_stories_outlined,
    ContentMode.novel => Icons.menu_book_outlined,
  };

  bool get isReading => this != ContentMode.anime;

  /// Which provider types belong to this mode. Anime mode keeps both video
  /// types so today's mixed anime/movie source list is unchanged.
  bool matchesProvider(ProviderType t) => switch (this) {
    ContentMode.anime => t == ProviderType.anime || t == ProviderType.movie,
    ContentMode.manga => t == ProviderType.manga,
    ContentMode.novel => t == ProviderType.novel,
  };
}

/// Filters a source map to the entries visible in [mode]. In anime mode this
/// is a no-op over an anime/movie-only source set — the hard requirement that
/// today's anime-mode source list never changes.
Map<String, T> filterSourcesForMode<T>(
  Map<String, T> sources,
  ContentMode mode,
  ProviderType Function(T) typeOf,
) => Map.fromEntries(
  sources.entries.where((e) => mode.matchesProvider(typeOf(e.value))),
);
