import 'package:flutter/material.dart';

class StremioLibraryBadge extends StatelessWidget {
  const StremioLibraryBadge({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Stremio',
    child: Container(
      width: 22,
      height: 22,
      padding: const EdgeInsets.all(2),
      decoration: const BoxDecoration(
        color: Color(0xCC000000),
        shape: BoxShape.circle,
      ),
      child: const DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [Color(0xFF8B5CF6), Color(0xFF6654D9)],
          ),
        ),
        child: Icon(Icons.play_arrow_rounded, size: 15, color: Colors.white),
      ),
    ),
  );
}
