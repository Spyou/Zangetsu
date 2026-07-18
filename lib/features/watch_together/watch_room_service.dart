import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase/supabase_service.dart';
import 'model/room_state.dart';
import 'sync_math.dart';

/// Supabase data layer for Watch Together rooms.
///
/// Transport is Realtime Broadcast + Presence on one channel per room
/// (`party:<code>`) — the 4s host beat, the participant roster, and chat are
/// ALL channel messages with zero database writes. The `watch_rooms` row is
/// written only on create / episode-change / pause-stop anchor / host
/// transfer / end (see [updateRoom]). No UI or player knowledge lives here.
class WatchRoomService {
  WatchRoomService(this._sb);
  final SupabaseService _sb;

  SupabaseClient get _c => _sb.client;

  static const _table = 'watch_rooms';

  // ── Channel bookkeeping ──────────────────────────────────────────────────

  final Map<String, RealtimeChannel> _channels = {};
  final Map<String, RoomState> _lastRoom = {};
  final Set<String> _subscribed = {};

  /// Returns the shared channel for [code] (creating it on first use). Does
  /// NOT subscribe — callers attach handlers first, then call [_ensureJoined].
  RealtimeChannel _channelFor(String code) =>
      _channels.putIfAbsent(code, () => _c.channel('party:$code'));

  /// Joins the channel exactly once, regardless of how many of
  /// watchRoom/watchParticipants/watchMessages/upsertParticipant race to
  /// attach handlers first (RealtimeChannel.subscribe() throws if called
  /// twice on the same instance).
  void _ensureJoined(String code) {
    if (!_subscribed.add(code)) return;
    _channels[code]?.subscribe();
  }

  /// Removes and unsubscribes the channel for [code] (idempotent).
  void closeChannel(String code) {
    final ch = _channels.remove(code);
    _lastRoom.remove(code);
    _subscribed.remove(code);
    if (ch != null) _c.removeChannel(ch);
  }

  // ── Room mapping ─────────────────────────────────────────────────────────

  Map<String, dynamic> _toRow(RoomState s) => {
        'code': s.code,
        'host_key': s.hostId,
        'status': s.status,
        'content': s.toMap(),
        'host_pos_ms': s.positionMs,
        'host_rate': s.rate,
        'host_playing': s.playing,
      };

  RoomState _fromRow(Map<String, dynamic> row) {
    final content = row['content'];
    final base = RoomState.fromMap({
      if (content is Map) ...content.cast<String, dynamic>(),
      'code': '${row['code'] ?? ''}',
    });
    return base.copyWith(
      status: '${row['status'] ?? base.status}',
      positionMs: (row['host_pos_ms'] as num?)?.toInt() ?? base.positionMs,
      rate: (row['host_rate'] as num?)?.toDouble() ?? base.rate,
      playing: row['host_playing'] as bool? ?? base.playing,
      hostId: '${row['host_key'] ?? base.hostId}',
    );
  }

  // ── Room CRUD ────────────────────────────────────────────────────────────

  /// Creates a room, retrying with a new code on PK collisions (up to 5x).
  Future<RoomState> createRoom(RoomState initial) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final code = generateRoomCode(
          DateTime.now().millisecondsSinceEpoch + attempt * 7919);
      final state = RoomState.fromMap({...initial.toMap(), 'code': code});
      try {
        await _c.from(_table).insert(_toRow(state));
        _lastRoom[code] = state;
        return state;
      } on PostgrestException catch (e) {
        if (e.code == '23505') continue; // unique_violation on code — retry
        rethrow;
      }
    }
    throw StateError('could not allocate a room code after 5 attempts');
  }

  /// Returns the room for [code], or null if it does not exist.
  Future<RoomState?> getRoom(String code) async {
    final row =
        await _c.from(_table).select().eq('code', code).maybeSingle();
    if (row == null) return null;
    final state = _fromRow(row);
    _lastRoom[code] = state;
    return state;
  }

  /// Applies a partial [patch] to the room row (best-effort; errors swallowed
  /// because the next heartbeat/action will retry). Used ONLY for episode
  /// change / pause-stop anchor / host transfer / end — NOT the 4s beat.
  Future<void> updateRoom(String code, Map<String, dynamic> patch) async {
    try {
      await _c.from(_table).update(patch).eq('code', code);
    } catch (_) {/* best-effort; next write retries */}
  }

  /// The 4s host beat: broadcasts {pos, rate, playing} to room [code] with
  /// ZERO database write. Not part of the original CRUD surface, but needed
  /// so the controller's heartbeat never has to reach into channel internals.
  Future<void> broadcastHostState(String code,
      {required int posMs, required double rate, required bool playing}) async {
    final ch = _channelFor(code);
    _ensureJoined(code);
    try {
      await ch.sendBroadcastMessage(event: 'host_state', payload: {
        'pos': posMs,
        'rate': rate,
        'playing': playing,
        'at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {/* best-effort; next beat retries */}
  }

  /// Emits a new [RoomState] whenever the host broadcasts a `host_state`
  /// tick or the `watch_rooms` row changes (episode/anchor/status updates).
  /// Seeds with the current row via [getRoom] first.
  Stream<RoomState> watchRoom(String code) {
    late final StreamController<RoomState> controller;

    void emit(RoomState s) {
      _lastRoom[code] = s;
      if (!controller.isClosed) controller.add(s);
    }

    controller = StreamController<RoomState>.broadcast(
      onListen: () async {
        final seed = _lastRoom[code] ?? await getRoom(code);
        if (seed != null) emit(seed);

        _channelFor(code)
          ..onBroadcast(
            event: 'host_state',
            callback: (payload) {
              final cur = _lastRoom[code];
              if (cur == null) return;
              emit(cur.copyWith(
                positionMs: (payload['pos'] as num?)?.toInt(),
                playing: payload['playing'] as bool?,
                rate: (payload['rate'] as num?)?.toDouble(),
                updatedAt: (payload['at'] as num?)?.toInt(),
              ));
            },
          )
          ..onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: _table,
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'code',
              value: code,
            ),
            callback: (payload) {
              if (payload.newRecord.isEmpty) return;
              emit(_fromRow(payload.newRecord));
            },
          );
        _ensureJoined(code);
      },
    );
    return controller.stream;
  }

  // ── Participants (Presence — no table) ──────────────────────────────────

  /// Tracks [p] in room [code]'s Presence state (create-or-update).
  Future<void> upsertParticipant(String code, RoomParticipant p) async {
    final ch = _channelFor(code);
    _ensureJoined(code);
    try {
      await ch.track(p.toMap());
    } catch (_) {/* best-effort; next beat/track retries */}
  }

  /// Untracks [userId] from room [code]'s Presence state (self-removal only —
  /// Presence has no notion of removing a peer).
  Future<void> removeParticipant(String code, String userId) async {
    final ch = _channels[code];
    if (ch == null) return;
    try {
      await ch.untrack();
    } catch (_) {}
  }

  /// Returns the current Presence roster for room [code].
  Future<List<RoomParticipant>> listParticipants(String code) async {
    final ch = _channels[code];
    if (ch == null) return const [];
    try {
      return ch
          .presenceState()
          .expand((s) => s.presences)
          .map((p) => RoomParticipant.fromMap(p.payload))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Emits a void tick whenever the Presence roster for room [code] changes
  /// (sync/join/leave). Caller should re-call [listParticipants] on each tick.
  Stream<void> watchParticipants(String code) {
    late final StreamController<void> controller;
    controller = StreamController<void>.broadcast(
      onListen: () {
        final ch = _channelFor(code);
        void tick() {
          if (!controller.isClosed) controller.add(null);
        }

        ch
          ..onPresenceSync((_) => tick())
          ..onPresenceJoin((_) => tick())
          ..onPresenceLeave((_) => tick());
        _ensureJoined(code);
      },
    );
    return controller.stream;
  }

  // ── Messages (Broadcast — no table, live-only) ──────────────────────────

  /// Broadcasts a chat message [m] to room [code]. No history is persisted.
  Future<void> sendMessage(String code, RoomMessage m) async {
    final ch = _channelFor(code);
    _ensureJoined(code);
    try {
      await ch.sendBroadcastMessage(event: 'chat', payload: m.toMap());
    } catch (_) {}
  }

  /// Chat is live-only by design (Broadcast has no history) — always empty.
  Future<List<RoomMessage>> recentMessages(String code, {int limit = 50}) =>
      Future.value(const []);

  /// Emits each chat message broadcast to room [code] in real time.
  Stream<RoomMessage> watchMessages(String code) {
    late final StreamController<RoomMessage> controller;
    controller = StreamController<RoomMessage>.broadcast(
      onListen: () {
        final ch = _channelFor(code);
        ch.onBroadcast(
          event: 'chat',
          callback: (payload) {
            if (!controller.isClosed) {
              controller.add(RoomMessage.fromMap(payload));
            }
          },
        );
        _ensureJoined(code);
      },
    );
    return controller.stream;
  }
}
