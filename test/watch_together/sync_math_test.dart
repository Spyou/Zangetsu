// test/watch_together/sync_math_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/watch_together/model/room_state.dart';
import 'package:watch_app/features/watch_together/sync_math.dart';

RoomState _room({required int positionMs, required bool playing, required int updatedAt}) =>
    RoomState(code: 'X', hostId: 'h', hostName: '', hostAvatar: '', sourceId: '',
        sourceLabel: '', showUrl: '', showTitle: '', cover: '', episodeId: '',
        episodeNumber: null, episodeUrl: '', category: 'sub', malId: null, tmdbId: null,
        positionMs: positionMs, playing: playing, rate: 1.0, updatedAt: updatedAt,
        status: 'active');

RoomParticipant _p(String id, {required int joinedAt, required int lastSeenAt, String state = 'watching'}) =>
    RoomParticipant(userId: id, name: id, avatar: '', state: state,
        joinedAt: joinedAt, lastSeenAt: lastSeenAt);

void main() {
  test('expectedPosition advances by elapsed wall-clock while playing', () {
    final r = _room(positionMs: 10000, playing: true, updatedAt: 1000);
    expect(expectedPosition(r, 4000), const Duration(milliseconds: 13000)); // +3000ms
  });

  test('expectedPosition is frozen while paused', () {
    final r = _room(positionMs: 10000, playing: false, updatedAt: 1000);
    expect(expectedPosition(r, 9999999), const Duration(milliseconds: 10000));
  });

  test('needsCorrection only past the threshold', () {
    expect(needsCorrection(const Duration(seconds: 10), const Duration(seconds: 11)), isFalse);
    expect(needsCorrection(const Duration(seconds: 10), const Duration(seconds: 14)), isTrue);
  });

  test('electSuccessor picks oldest non-stale non-host participant', () {
    final list = [
      _p('host', joinedAt: 0, lastSeenAt: 1000),
      _p('b', joinedAt: 50, lastSeenAt: 1000),
      _p('a', joinedAt: 20, lastSeenAt: 1000), // oldest after host
    ];
    expect(electSuccessor(list, leavingHostId: 'host', nowMs: 1000), 'a');
  });

  test('electSuccessor skips stale + left participants, null when none', () {
    final list = [
      _p('host', joinedAt: 0, lastSeenAt: 1000),
      _p('stale', joinedAt: 10, lastSeenAt: 1), // nowMs-lastSeen > staleMs
      _p('left', joinedAt: 20, lastSeenAt: 1000, state: 'left'),
    ];
    expect(electSuccessor(list, leavingHostId: 'host', nowMs: 999999), isNull);
  });

  test('generateRoomCode is 6 chars from the safe alphabet, deterministic per seed', () {
    final c = generateRoomCode(123456);
    expect(c.length, 6);
    expect(RegExp(r'^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$').hasMatch(c), isTrue);
    expect(generateRoomCode(123456), c); // deterministic
  });
}
