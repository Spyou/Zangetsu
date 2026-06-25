// test/watch_together/room_state_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/watch_together/model/room_state.dart';

void main() {
  test('RoomState survives a map round-trip', () {
    const r = RoomState(
      code: 'ABC234', hostId: 'u1', hostName: 'Kr', hostAvatar: '',
      sourceId: 'cs:hd', sourceLabel: '4K HDHUB', showUrl: 'https://x/y',
      showTitle: 'Demo', cover: 'https://x/c.jpg', episodeId: 'S1E1',
      episodeNumber: 1, episodeUrl: 'data://1', category: 'sub',
      malId: 42, tmdbId: null, positionMs: 1000, playing: true, rate: 1.0,
      updatedAt: 99, status: 'active',
    );
    final back = RoomState.fromMap(r.toMap());
    expect(back, equals(r));
    expect(back.positionMs, 1000);
    expect(back.playing, true);
  });

  test('RoomParticipant + RoomMessage round-trip', () {
    const p = RoomParticipant(
        userId: 'u1', name: 'Kr', avatar: '', state: 'watching',
        joinedAt: 10, lastSeenAt: 20);
    expect(RoomParticipant.fromMap(p.toMap()), equals(p));
    const m = RoomMessage(userId: 'u1', name: 'Kr', avatar: '', text: 'hi', createdAt: 5);
    expect(RoomMessage.fromMap(m.toMap()), equals(m));
  });
}
