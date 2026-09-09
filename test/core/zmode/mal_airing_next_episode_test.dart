// MAL has no `nextAiringEpisode`. It reports the ANNOUNCED episode count, so a
// currently-airing show lists episodes that have not gone out yet — and the
// Detail screen used to blame whichever source it had checked ("Not on
// HiAnime") for an episode that simply had not aired. A weekly TV anime with a
// known start date has aired one episode per week since, which is enough to
// tell the two apart.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/mal_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

const _show = ZCanonical(ZKind.anime, 'mal:100');

String _ago(int days) =>
    DateTime.now().subtract(Duration(days: days)).toIso8601String().split('T').first;

MalCatalogue _mal({
  required String status,
  required int episodes,
  String? startDate,
}) {
  final dio = Dio()
    ..httpClientAdapter = _Adapter(
      (_) => {
        'id': 100,
        'title': 'A Show',
        'num_episodes': episodes,
        'status': status,
        if (startDate != null) 'start_date': startDate,
      },
    );
  return MalCatalogue(dio);
}

void main() {
  test('an airing show reports the first episode that has not aired', () async {
    // Started 4 weeks and change ago → 5 out, 6 is next.
    final d = await _mal(
      status: 'currently_airing',
      episodes: 13,
      startDate: _ago(30),
    ).detail(_show);
    expect(d.nextEpisode, 6);
    // The full announced list is still offered — hiding episodes would pretend
    // the season is shorter than it is.
    expect(d.episodes.length, 13);
  });

  test('a finished show claims nothing about airing', () async {
    final d = await _mal(
      status: 'finished_airing',
      episodes: 13,
      startDate: _ago(900),
    ).detail(_show);
    expect(d.nextEpisode, isNull);
  });

  test('an airing show with no start date claims nothing', () async {
    final d = await _mal(status: 'currently_airing', episodes: 13).detail(_show);
    expect(d.nextEpisode, isNull);
  });

  test('an open-ended show (num_episodes 0) claims nothing', () async {
    // One Piece. There is no announced total to count against.
    final d = await _mal(
      status: 'currently_airing',
      episodes: 0,
      startDate: _ago(9000),
    ).detail(_show);
    expect(d.nextEpisode, isNull);
  });

  test('a show that has finished airing its announced count claims nothing',
      () async {
    // Past the end: every episode is out, so nothing is pending.
    final d = await _mal(
      status: 'currently_airing',
      episodes: 13,
      startDate: _ago(200),
    ).detail(_show);
    expect(d.nextEpisode, isNull);
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Map<String, dynamic> Function(Map<String, dynamic>) respond;

  @override
  Future<ResponseBody> fetch(RequestOptions options, _, __) async {
    final body = respond(Map<String, dynamic>.from(options.queryParameters));
    return ResponseBody.fromString(
      const JsonEncoder().convert(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
