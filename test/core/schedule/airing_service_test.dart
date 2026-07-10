import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/schedule/airing_service.dart';
import 'package:watch_app/core/schedule/schedule_models.dart';

void main() {
  test('weekWindowUtc spans local-midnight-today .. +7 days', () {
    final now = DateTime(2026, 7, 10, 15, 30); // local
    final w = weekWindowUtc(now);
    final start = DateTime.fromMillisecondsSinceEpoch(w.startSec * 1000).toLocal();
    final end = DateTime.fromMillisecondsSinceEpoch(w.endSec * 1000).toLocal();
    expect(start, DateTime(2026, 7, 10)); // local midnight today
    expect(end, DateTime(2026, 7, 17));   // +7 days
    expect(w.endSec - w.startSec, 7 * 24 * 3600);
  });

  test('parseAiringSchedules maps fields, prefers english, drops adult/null', () {
    final data = {
      'Page': {
        'airingSchedules': [
          {
            'episode': 5,
            'airingAt': 1783000000,
            'media': {
              'idMal': 111,
              'title': {'romaji': 'Romaji Name', 'english': 'English Name'},
              'coverImage': {'large': 'http://x/c.jpg'},
              'format': 'TV',
              'isAdult': false,
            },
          },
          {
            'episode': 1,
            'airingAt': 1783100000,
            'media': {
              'idMal': 999,
              'title': {'romaji': 'Adult Show', 'english': null},
              'coverImage': {'large': null},
              'format': 'ONA',
              'isAdult': true, // dropped
            },
          },
          {'episode': 2, 'airingAt': 1783200000, 'media': null}, // dropped
        ],
      },
    };
    final out = parseAiringSchedules(Map<String, dynamic>.from(data));
    expect(out.length, 1);
    expect(out.first.title, 'English Name');
    expect(out.first.malId, 111);
    expect(out.first.episode, 5);
    expect(out.first.format, 'TV');
    expect(out.first.coverUrl, 'http://x/c.jpg');
    expect(out.first.airsAtLocal,
        DateTime.fromMillisecondsSinceEpoch(1783000000 * 1000).toLocal());
  });

  test('parseAiringSchedules falls back to romaji when english is null/empty', () {
    final data = {
      'Page': {
        'airingSchedules': [
          {
            'episode': 1,
            'airingAt': 1783000000,
            'media': {
              'idMal': 1,
              'title': {'romaji': 'Only Romaji', 'english': ''},
              'coverImage': {'large': 'c'},
              'format': 'TV',
              'isAdult': false,
            },
          },
        ],
      },
    };
    expect(parseAiringSchedules(Map<String, dynamic>.from(data)).first.title,
        'Only Romaji');
  });

  test('parseAiringSchedules returns [] on missing/garbage shape', () {
    expect(parseAiringSchedules(const {}), isEmpty);
    expect(parseAiringSchedules(const {'Page': null}), isEmpty);
  });

  test('groupByLocalDay buckets by local calendar day, time-sorted', () {
    AiringEntry e(int atSec) => AiringEntry(
          malId: 1, title: 't', coverUrl: null, episode: 1,
          airsAtLocal: DateTime.fromMillisecondsSinceEpoch(atSec * 1000).toLocal(),
          format: 'TV');
    final day1a = e(1783000000);
    final day1b = e(1783000000 + 3600); // same day, 1h later
    final day2 = e(1783000000 + 24 * 3600 * 2); // +2 days
    final grouped = groupByLocalDay([day1b, day2, day1a]);
    final firstDay = DateTime(day1a.airsAtLocal.year, day1a.airsAtLocal.month, day1a.airsAtLocal.day);
    expect(grouped[firstDay]!.map((x) => x.airsAtLocal).toList(),
        [day1a.airsAtLocal, day1b.airsAtLocal]); // sorted ascending
    expect(grouped.keys.length, 2);
  });

  test('filterByMalIds keeps only matching malIds', () {
    AiringEntry e(int? mal) => AiringEntry(
        malId: mal, title: 't', coverUrl: null, episode: 1,
        airsAtLocal: DateTime(2026), format: 'TV');
    final out = filterByMalIds([e(1), e(2), e(null), e(3)], {1, 3});
    expect(out.map((x) => x.malId).toList(), [1, 3]);
  });
}
