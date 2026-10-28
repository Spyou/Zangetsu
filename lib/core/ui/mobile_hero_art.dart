/// Portrait TMDB artwork suits a tall phone hero; keep other catalogues' art.
String? mobileHeroArt(String? cover, String? banner) {
  if (cover != null && cover.startsWith('https://image.tmdb.org/t/p/')) {
    return cover.replaceFirst(RegExp(r'/t/p/[^/]+/'), '/t/p/original/');
  }
  return banner ?? cover;
}

/// Detail backgrounds sample the poster first, falling back to the backdrop.
String? adaptiveArtUrl(String? poster, String? backdrop) {
  if (poster != null && poster.trim().isNotEmpty) return poster;
  return backdrop != null && backdrop.trim().isNotEmpty ? backdrop : null;
}
