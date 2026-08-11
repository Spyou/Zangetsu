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

  test('the core team lists Krishna, Ombryal (dual role) and Riyoc', () {
    expect(kCoreTeam.map((m) => m.name), [
      'Krishna Vishwakarma',
      'Ombryal',
      'Riyoc',
    ]);
    expect(kCoreTeam[1].role, contains('Discord Head Admin'));
    expect(kCoreTeam[1].role, contains('Contributor'));
  });

  test('TeamMember.avatar falls back to the GitHub avatar, then empty', () {
    const gh = TeamMember(name: 'x', role: 'r', link: 'l', github: 'octocat');
    expect(gh.avatar, 'https://github.com/octocat.png?size=200');
    const manual = TeamMember(name: 'Riyoc', role: 'r', link: 'l');
    expect(manual.avatar, '');
  });
}
