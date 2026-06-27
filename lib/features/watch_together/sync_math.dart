import 'dart:math';

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
  // Use dart:math Random for a well-distributed code over the FULL 32^6 (~1B)
  // space. The old hand-rolled LCG took the LOW 5 bits (`x % 32`), which for an
  // LCG mod 2^31 cycle with period 32 — so the whole 6-char code was determined
  // by `seed % 32`, i.e. only 32 distinct codes ever existed. Once ~32 rooms
  // had been created, every new code collided (409 document_already_exists) and
  // room creation failed permanently. Random(seed) is uniform AND deterministic
  // per seed (so getRoom/retry behaviour and tests still hold).
  final rng = Random(seed);
  final b = StringBuffer();
  for (var i = 0; i < 6; i++) {
    b.write(_alphabet[rng.nextInt(_alphabet.length)]);
  }
  return b.toString();
}
