// lib/features/watch_together/watch_together_controller.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../auth/auth_cubit.dart';
import '../../core/di/injector.dart';
import 'model/room_state.dart';
import 'sync_math.dart';
import 'watch_room_service.dart';

class WatchTogetherController extends ChangeNotifier {
  WatchTogetherController(this._svc);
  final WatchRoomService _svc;

  RoomState? room;
  RoomRole role = RoomRole.none;
  List<RoomParticipant> participants = const [];
  bool synced = true;

  // Provided by the player integration (Task 6).
  void Function(bool playing, Duration pos, double rate)? onApplyRemote;
  Duration Function()? localPosition;
  void Function(RoomState room)? onEpisodeChange; // client must (re)load episode

  StreamSubscription<RoomState>? _roomSub;
  StreamSubscription<void>? _partSub;
  Timer? _hostBeat, _presenceBeat;
  String? _lastEpisodeId;

  String get _uid => sl<AuthCubit>().state.user?.$id ?? '';
  String get _uname => sl<AuthCubit>().state.user?.name ?? 'Guest';
  bool get isHost => role == RoomRole.host;
  int get _now => DateTime.now().millisecondsSinceEpoch;

  Future<void> host(RoomState initial) async {
    final created = await _svc.createRoom(initial.copyWith(
        hostId: _uid, hostName: _uname, updatedAt: _now, status: 'active'));
    room = created;
    role = RoomRole.host;
    _lastEpisodeId = created.episodeId;
    await _enter(created.code);
  }

  Future<bool> join(String code) async {
    final r = await _svc.getRoom(code);
    if (r == null || r.status == 'ended') return false;
    room = r;
    role = RoomRole.client;
    _lastEpisodeId = r.episodeId;
    await _enter(code);
    // Apply the current state right away.
    onEpisodeChange?.call(r);
    _applyRoom(r);
    return true;
  }

  Future<void> _enter(String code) async {
    await _svc.upsertParticipant(code, RoomParticipant(
        userId: _uid, name: _uname, avatar: '', state: 'watching',
        joinedAt: _now, lastSeenAt: _now));
    _roomSub = _svc.watchRoom(code).listen(_onRoom);
    _partSub = _svc.watchParticipants(code).listen((_) => _refreshParticipants(code));
    _presenceBeat = Timer.periodic(const Duration(seconds: 10), (_) {
      _svc.upsertParticipant(code, RoomParticipant(userId: _uid, name: _uname,
          avatar: '', state: 'watching', joinedAt: room?.updatedAt ?? _now,
          lastSeenAt: _now));
      _maybePromoteSelf(); // crash-failover check
    });
    if (isHost) {
      _hostBeat = Timer.periodic(const Duration(seconds: 4), (_) {
        final r = room; final pos = localPosition?.call();
        if (r != null && r.playing && pos != null) {
          _writeHost(positionMs: pos.inMilliseconds);
        }
      });
    }
    await _refreshParticipants(code);
    notifyListeners();
  }

  Future<void> _refreshParticipants(String code) async {
    participants = await _svc.listParticipants(code);
    notifyListeners();
  }

  void _onRoom(RoomState r) {
    final wasHost = isHost;
    room = r;
    // Host handoff: this client just became the named host.
    if (!wasHost && r.hostId == _uid) {
      role = RoomRole.host;
      _hostBeat ??= Timer.periodic(const Duration(seconds: 4), (_) {
        final cur = room; final pos = localPosition?.call();
        if (cur != null && cur.playing && pos != null) {
          _writeHost(positionMs: pos.inMilliseconds);
        }
      });
    }
    if (r.episodeId != _lastEpisodeId) {
      _lastEpisodeId = r.episodeId;
      if (!isHost) onEpisodeChange?.call(r);
    }
    if (!isHost) _applyRoom(r);
    notifyListeners();
  }

  void _applyRoom(RoomState r) {
    final local = localPosition?.call();
    final expected = expectedPosition(r, _now);
    if (local != null) synced = !needsCorrection(local, expected);
    onApplyRemote?.call(r.playing, expected, r.rate);
  }

  // ---- host broadcast ----
  void broadcastPlay(Duration p) { if (isHost) _writeHost(playing: true, positionMs: p.inMilliseconds); }
  void broadcastPause(Duration p) { if (isHost) _writeHost(playing: false, positionMs: p.inMilliseconds); }
  void broadcastSeek(Duration p) { if (isHost) _writeHost(positionMs: p.inMilliseconds); }
  void broadcastEpisode({required String episodeId, required double? number,
      required String episodeUrl}) {
    if (!isHost) return;
    _lastEpisodeId = episodeId;
    _writeHost(extra: {'episodeId': episodeId, 'episodeNumber': number,
        'episodeUrl': episodeUrl, 'positionMs': 0});
  }

  void _writeHost({bool? playing, int? positionMs, Map<String, dynamic>? extra}) {
    final code = room?.code; if (code == null) return;
    final patch = <String, dynamic>{'updatedAt': _now, ...?extra};
    if (playing != null) patch['playing'] = playing;
    if (positionMs != null) patch['positionMs'] = positionMs;
    room = room?.copyWith(
        playing: playing, positionMs: positionMs,
        updatedAt: patch['updatedAt'] as int);
    _svc.updateRoom(code, patch);
  }

  // ---- migration ----
  void _maybePromoteSelf() {
    final r = room; if (r == null || isHost) return;
    final hostStale = !participants.any((p) =>
        p.userId == r.hostId && _now - p.lastSeenAt <= 30000);
    if (!hostStale) return;
    final successor = electSuccessor(participants, leavingHostId: r.hostId, nowMs: _now);
    if (successor == _uid) {
      _writeHost(extra: {'hostId': _uid, 'hostName': _uname});
      role = RoomRole.host;
      notifyListeners();
    }
  }

  Future<void> leave() async {
    final code = room?.code;
    if (code != null && isHost) {
      final successor = electSuccessor(participants, leavingHostId: _uid, nowMs: _now);
      if (successor != null) {
        await _svc.updateRoom(code, {'hostId': successor, 'updatedAt': _now});
      } else {
        await _svc.updateRoom(code, {'status': 'ended', 'updatedAt': _now});
      }
    }
    if (code != null) await _svc.removeParticipant(code, _uid);
    _teardown();
  }

  void _teardown() {
    _roomSub?.cancel(); _partSub?.cancel();
    _hostBeat?.cancel(); _presenceBeat?.cancel();
    _hostBeat = _presenceBeat = null;
    room = null; role = RoomRole.none; participants = const [];
    notifyListeners();
  }

  @override
  void dispose() { _teardown(); super.dispose(); }
}
