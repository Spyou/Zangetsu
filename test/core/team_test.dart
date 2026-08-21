import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/team_section.dart';

void main() {
  test('parseCommunity drops core team, ghost + bots, tags Contributor', () {
    final json = [
      {'login': 'Spyou', 'html_url': 'h1', 'type': 'User'},
      {'login': 'Ombryal', 'html_url': 'ho', 'type': 'User'},
      {'login': 'chatgptkrylor', 'html_url': 'h2', 'type': 'User'},
      {'login': 'dependabot[bot]', 'html_url': 'h3', 'type': 'Bot'},
      {'login': 'newHelper', 'avatar_url': 'x', 'html_url': 'hx', 'type': 'User'},
    ];
    final out = parseCommunity(json);

    // Only the genuinely new contributor survives; everyone curated/ghost/bot
    // is filtered out.
    expect(out.map((m) => m.name).toList(), ['newHelper']);
    expect(out.single.role, 'Contributor');
    expect(out.single.avatarUrl, 'x');
  });

  test('parseCommunity is empty when only the core team has contributed', () {
    final json = [
      {'login': 'Spyou', 'type': 'User'},
      {'login': 'Ombryal', 'type': 'User'},
      {'login': 'chatgptkrylor', 'type': 'User'},
    ];
    expect(parseCommunity(json), isEmpty);
  });

  test('the core team lists Krishna, NeighborhoodNerd and Ombryal (dual role)',
      () {
    expect(kCoreTeam.map((m) => m.name), [
      'Krishna Vishwakarma',
      'NeighborhoodNerd',
      'Ombryal',
    ]);
    expect(kCoreTeam[2].role, contains('Discord Head Admin'));
    expect(kCoreTeam[2].role, contains('Contributor'));
  });

  test('a core member is not repeated under Community Contributors', () {
    for (final m in kCoreTeam) {
      final gh = m.github;
      if (gh != null) expect(kExcludedFromCommunity, contains(gh));
    }
  });

  test('Riyoc is listed by hand, since no commit carries his name', () {
    expect(kFixedCommunity.map((m) => m.name), contains('Riyoc'));
    expect(kFixedCommunity.single.github, isNull);
  });

  test('TeamMember.avatar falls back to the GitHub avatar, then empty', () {
    const gh = TeamMember(name: 'x', role: 'r', link: 'l', github: 'octocat');
    expect(gh.avatar, 'https://github.com/octocat.png?size=200');
    const manual = TeamMember(name: 'Riyoc', role: 'r', link: 'l');
    expect(manual.avatar, '');
  });
}
