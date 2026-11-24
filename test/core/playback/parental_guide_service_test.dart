import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/parental_guide_service.dart';

Map<String, dynamic> _cat(String name, int none, int mild, int mod, int sev) =>
    {
      'category': name,
      'severityBreakdowns': [
        {'severityLevel': 'none', 'voteCount': none},
        {'severityLevel': 'mild', 'voteCount': mild},
        {'severityLevel': 'moderate', 'voteCount': mod},
        {'severityLevel': 'severe', 'voteCount': sev},
      ],
    };

void main() {
  test('worst first, ties keep the category order, labels are title-cased', () {
    final warnings = ParentalGuideService.parse({
      'parentsGuide': [
        _cat('ALCOHOL_DRUGS', 10, 50, 5, 0),
        _cat('PROFANITY', 10, 60, 5, 0),
        _cat('FRIGHTENING_INTENSE_SCENES', 5, 5, 80, 10),
        _cat('VIOLENCE', 5, 5, 90, 10),
      ],
    });
    expect(warnings.map((w) => '${w.label} · ${w.severity}').toList(), [
      'Violence · Moderate',
      'Frightening · Moderate',
      'Profanity · Mild',
      'Alcohol/Drugs · Mild',
    ]);
  });

  test('a category where "none" wins is left out', () {
    final warnings = ParentalGuideService.parse({
      'parentsGuide': [
        _cat('SEXUAL_CONTENT', 500, 100, 20, 0),
        _cat('VIOLENCE', 5, 5, 5, 90),
      ],
    });
    expect(warnings, [const ParentalWarning('Violence', 'Severe')]);
  });

  test('junk or missing data gives no warnings instead of throwing', () {
    expect(ParentalGuideService.parse(null), isEmpty);
    expect(ParentalGuideService.parse({'parentsGuide': 'nope'}), isEmpty);
    expect(
      ParentalGuideService.parse({
        'parentsGuide': [
          {'category': 'VIOLENCE'},
          5,
        ],
      }),
      isEmpty,
    );
  });

  test('levels the service invents are never shown', () {
    final warnings = ParentalGuideService.parse({
      'parentsGuide': [
        {
          'category': 'VIOLENCE',
          'severityBreakdowns': [
            {'severityLevel': 'none', 'voteCount': 1},
            {'severityLevel': '', 'voteCount': 900},
            {'severityLevel': 'ultra-extreme', 'voteCount': 800},
            {'severityLevel': 'mild', 'voteCount': 50},
          ],
        },
      ],
    });
    expect(warnings, [const ParentalWarning('Violence', 'Mild')]);
  });
}
