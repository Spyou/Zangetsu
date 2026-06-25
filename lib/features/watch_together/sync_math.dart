import 'model/room_state.dart';

const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

Duration expectedPosition(RoomState room, int localNowMs) {
  if (!room.playing) return Duration(milliseconds: room.positionMs);
  final ms = room.positionMs + (localNowMs - room.updatedAt);
  return Duration(milliseconds: ms < 0 ? 0 : ms);
}

bool needsCorrection(Duration localPos, Duration expected,
        {Duration threshold = const Duration(milliseconds: 2500)}) =>
    (localPos - expected).abs() > threshold;

String? electSuccessor(List<RoomParticipant> participants,
    {required String leavingHostId, required int nowMs, int staleMs = 30000}) {
  final candidates = participants
      .where((p) => p.userId != leavingHostId)
      .where((p) => p.state != 'left')
      .where((p) => nowMs - p.lastSeenAt <= staleMs)
      .toList()
    ..sort((a, b) {
      final j = a.joinedAt.compareTo(b.joinedAt);
      return j != 0 ? j : a.userId.compareTo(b.userId);
    });
  return candidates.isEmpty ? null : candidates.first.userId;
}

String generateRoomCode(int seed) {
  var x = seed & 0x7fffffff;
  final b = StringBuffer();
  for (var i = 0; i < 6; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff; // LCG — deterministic per seed
    b.write(_alphabet[x % _alphabet.length]);
  }
  return b.toString();
}
