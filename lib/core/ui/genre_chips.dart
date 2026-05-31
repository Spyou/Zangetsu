import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

const List<String> kGenres = [
  'Action',
  'Adventure',
  'Comedy',
  'Drama',
  'Fantasy',
  'Romance',
  'Sci-Fi',
  'Slice of Life',
  'Isekai',
  'Sports',
  'Mystery',
  'Supernatural',
];

/// Horizontal scrollable row of genre pill buttons.
///
/// Each pill is a [DecoratedBox] with surface2 fill, radius 20 and h14/v8
/// padding. No [BackdropFilter].
class GenreChips extends StatelessWidget {
  const GenreChips({super.key, required this.onTap});

  final void Function(String genre) onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        cacheExtent: 600,
        itemCount: kGenres.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final genre = kGenres[index];
          return _GenreChip(label: genre, onTap: () => onTap(genre));
        },
      ),
    );
  }
}

class _GenreChip extends StatelessWidget {
  const _GenreChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: AppText.caption.copyWith(color: AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}
