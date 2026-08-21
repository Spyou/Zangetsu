import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A person on the Contributors page — a curated core member with a role, or a
/// community contributor auto-pulled from the repo's GitHub contributors.
class TeamMember {
  const TeamMember({
    required this.name,
    required this.role,
    required this.link,
    this.github,
    this.avatarUrl,
  });

  final String name;
  final String role;
  final String link; // opened on tap (GitHub / Discord / …)
  final String? github; // login → avatar + default link
  final String? avatarUrl;

  /// Avatar image url: an explicit one, else the GitHub avatar, else empty
  /// (the tile falls back to the name's initial).
  String get avatar =>
      avatarUrl ??
      (github != null ? 'https://github.com/$github.png?size=200' : '');
}

/// The curated core team, shown first on the Contributors page with their
/// specific roles. Everyone else who contributes on GitHub shows up under
/// "Community Contributors" automatically.
const List<TeamMember> kCoreTeam = [
  TeamMember(
    name: 'Krishna Vishwakarma',
    role: 'Lead Developer',
    github: 'spyou',
    link: 'https://github.com/spyou',
  ),
  TeamMember(
    name: 'NeighborhoodNerd',
    role: 'Contributor',
    github: 'neighborhoodnerd',
    link: 'https://github.com/NeighborhoodNerd',
  ),
  TeamMember(
    name: 'Ombryal',
    role: 'Discord Head Admin · Contributor',
    github: 'ombryal',
    link: 'https://github.com/Ombryal',
  ),
];

/// Community contributors we list by hand, ahead of the GitHub-pulled ones.
/// For people whose work never landed as a commit — art, design — so the
/// contributors fetch can't find them.
const List<TeamMember> kFixedCommunity = [
  TeamMember(
    name: 'Riyoc',
    role: 'New logo creator',
    link: 'https://discord.com/users/1443370547877646447',
  ),
];

/// GitHub logins NOT shown under Community Contributors: the curated core (they
/// already appear above) and known ghost / bot accounts.
const Set<String> kExcludedFromCommunity = {
  'spyou',
  'ombryal',
  'neighborhoodnerd',
  'chatgptkrylor',
};

/// Map GitHub's `/contributors` payload to community [TeamMember]s: drop the
/// core + ghost logins and bots, tag everyone else as "Contributor". GitHub
/// returns them sorted by contribution count, which we keep.
List<TeamMember> parseCommunity(List<dynamic> json) {
  final out = <TeamMember>[];
  for (final e in json) {
    if (e is! Map) continue;
    final login = (e['login'] ?? '').toString();
    if (login.isEmpty) continue;
    final type = (e['type'] ?? '').toString();
    if (type == 'Bot' || login.toLowerCase().endsWith('[bot]')) continue;
    if (kExcludedFromCommunity.contains(login.toLowerCase())) continue;
    final avatar = (e['avatar_url'] ?? '').toString();
    out.add(
      TeamMember(
        name: login,
        role: 'Contributor',
        github: login,
        link: (e['html_url'] ?? 'https://github.com/$login').toString(),
        avatarUrl: avatar.isEmpty ? null : avatar,
      ),
    );
  }
  return out;
}

/// Fetch the community contributors (everyone on GitHub minus the core team).
/// Fails soft — an empty list just hides the section's rows.
// ponytail: unauthenticated GitHub API = 60 req/hr per IP; a rarely-opened
// credits page won't get near that, so no caching.
Future<List<TeamMember>> fetchCommunity() async {
  try {
    final resp = await Dio().get<List<dynamic>>(
      'https://api.github.com/repos/Spyou/Zangetsu/contributors',
      queryParameters: const {'per_page': 100, 'anon': 0},
      options: Options(
        responseType: ResponseType.json,
        sendTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    return parseCommunity(resp.data ?? const []);
  } catch (_) {
    return const [];
  }
}

/// Circular avatar for a contributor — GitHub/explicit image with the name's
/// initial as the fallback.
class TeamAvatar extends StatelessWidget {
  const TeamAvatar({
    super.key,
    required this.url,
    required this.name,
    this.size = 42,
  });

  final String url;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.08),
      ),
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style: TextStyle(
          fontFamily: 'Inter',
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.4,
        ),
      ),
    );
    if (url.isEmpty) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 180),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}
