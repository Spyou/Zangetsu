import 'package:flutter/material.dart';

/// A tracker's mark — its brand colour and short name in a rounded tile, the
/// way AniList/MAL/Simkl are recognised at a glance.
///
/// Drawn rather than shipped as image assets: three more PNGs per density is
/// weight for something this small, and drawing it keeps the mark crisp at any
/// size and correct on both themes.
class TrackerBadge extends StatelessWidget {
  const TrackerBadge({super.key, required this.name, this.size = 34});

  /// The tracker's `displayName` — matched case-insensitively, so an unknown
  /// tracker still gets a sensible neutral badge instead of blowing up.
  final String name;
  final double size;

  ({Color bg, String label, double scale}) get _brand {
    switch (name.toLowerCase()) {
      // AniList's blue, from its own branding.
      case 'anilist':
        return (bg: const Color(0xFF02A9FF), label: 'AL', scale: 0.36);
      // MAL's navy.
      case 'myanimelist':
      case 'mal':
        return (bg: const Color(0xFF2E51A2), label: 'MAL', scale: 0.28);
      case 'simkl':
        return (bg: const Color(0xFF0B1622), label: 'SK', scale: 0.36);
      default:
        return (
          bg: const Color(0xFF3A3A3C),
          label: name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          scale: 0.40,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _brand;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: b.bg,
        borderRadius: BorderRadius.circular(size * 0.26),
      ),
      child: Text(
        b.label,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * b.scale,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
      ),
    );
  }
}
