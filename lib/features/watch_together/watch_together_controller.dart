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
  List<RoomMessage> messages = const [];
  bool synced = true;

  // Provided by the player integration (Task 6).
  void Function(bool playing, Duration pos, double rate)? onApplyRemote;
  Duration Function()? localPosition;
  void Function(RoomState room)? onEpisodeChange; // client must (re)load episode

  StreamSubscription<RoomState>? _roomSub;
  StreamSubscription<void>? _partSub;
  StreamSubscription<RoomMessage>? _msgSub;
  Timer? _hostBeat, _presenceBeat;
  String? _lastEpisodeId;
  int? _joinedAt;
  bool _wantsControl = false;
  bool _disposed = false;

  String get _uid => sl<AuthCubit>().state.user?.$id ?? '';
  String get _uname => sl<AuthCubit>().state.user?.name ?? 'Guest';
  bool get isHost => role == RoomRole.host;
  bool get canControl => isHost;
  int get _now => DateTime.now().millisecondsSinceEpoch;

  Future<void> host(RoomState initial) async {
    if (room != null) return;
    final created = await _svc.createRoom(initial.copyWith(
        hostId: _uid, hostName: _uname, updatedAt: _now, status: 'active'));
    room = created;
    role = RoomRole.host;
    _lastEpisodeId = created.episodeId;
    await _enter(created.code);
  }

  Future<bool> join(String code) async {
    if (room != null) return false;
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

  void _startHostBeat() {
    _wantsControl = false;
    _hostBeat ??= Timer.periodic(const Duration(seconds: 4), (_) {
      final r = room;
      final pos = localPosition?.call();
      if (r != null && r.playing && pos != null) {
        _writeHost(positionMs: pos.inMilliseconds);
      }
    });
  }

  void _subscribeRoom(String code) {
    _roomSub?.cancel();
    _roomSub = _svc.watchRoom(code).listen(
      _onRoom,
      onError: (_) => _resyncRoom(code),
      onDone: () => _resyncRoom(code),
    );
  }

  Future<void> _resyncRoom(String code) async {
    if (room == null) return;                          // left — don't reconnect
    await Future.delayed(const Duration(seconds: 2));  // backoff — never a tight loop
    if (room == null) return;                          // left during the backoff
    try {
      final r = await _svc.getRoom(code);
      if (r == null || room == null) return;           // room deleted (404) or left — stop
      _onRoom(r);
      _subscribeRoom(code);                            // re-attach; further drops re-enter here (2s-paced)
    } catch (_) {
      // Transient error (e.g. network) — re-attach; if it errors again the
      // onError handler re-enters _resyncRoom, which re-applies the 2s backoff.
      if (room != null) _subscribeRoom(code);
    }
  }

  Future<void> _enter(String code) async {
    _joinedAt ??= _now;
    await _svc.upsertParticipant(code, RoomParticipant(
        userId: _uid, name: _uname, avatar: '', state: 'watching',
        joinedAt: _joinedAt ?? _now, lastSeenAt: _now,
        wantsControl: _wantsControl));
    _subscribeRoom(code);
    _partSub = _svc.watchParticipants(code).listen((_) => _refreshParticipants(code));
    _presenceBeat = Timer.periodic(const Duration(seconds: 10), (_) {
      _svc.upsertParticipant(code, RoomParticipant(userId: _uid, name: _uname,
          avatar: '', state: 'watching', joinedAt: _joinedAt ?? _now,
          lastSeenAt: _now, wantsControl: _wantsControl));
      _maybePromoteSelf(); // crash-failover check
    });
    if (isHost) _startHostBeat();
    await _refreshParticipants(code);
    messages = await _svc.recentMessages(code);
    _msgSub = _svc.watchMessages(code).listen((m) {
      messages = [...messages, m];
      notifyListeners();
    });
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
      _startHostBeat();
    }
    // Demotion: this client lost a host-election race — stop acting as host.
    if (wasHost && r.hostId != _uid) {
      role = RoomRole.client;
      _hostBeat?.cancel();
      _hostBeat = null;
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
      role = RoomRole.host;
      _startHostBeat();
      _writeHost(extra: {'hostId': _uid, 'hostName': _uname});
      notifyListeners();
    }
  }

  // ---- control handoff ----
  Future<void> requestControl() async {
    if (isHost) return;
    final code = room?.code; if (code == null) return;
    _wantsControl = true;
    notifyListeners();
    await _svc.upsertParticipant(code, RoomParticipant(
        userId: _uid, name: _uname, avatar: '', state: 'watching',
        joinedAt: _joinedAt ?? _now, lastSeenAt: _now, wantsControl: true));
  }

  Future<void> transferHost(String uid) async {
    if (!isHost || uid.isEmpty || uid == _uid) return;
    final name = participants.firstWhere(
        (p) => p.userId == uid,
        orElse: () => const RoomParticipant(
            userId: '', name: '', avatar: '', state: '', joinedAt: 0, lastSeenAt: 0))
        .name;
    _writeHost(extra: {'hostId': uid, 'hostName': name});
  }

  Future<void> grantControl(String uid) async {
    await transferHost(uid);
    final code = room?.code; if (code == null) return;
    final existing = participants.firstWhere(
        (p) => p.userId == uid,
        orElse: () => const RoomParticipant(
            userId: '', name: '', avatar: '', state: 'watching', joinedAt: 0, lastSeenAt: 0));
    if (existing.userId.isEmpty) return;
    await _svc.upsertParticipant(code, existing.copyWith(
        wantsControl: false, lastSeenAt: _now));
  }

  Future<void> sendChat(String text) async {
    final code = room?.code;
    final t = text.trim();
    if (code == null || t.isEmpty) return;
    await _svc.sendMessage(code, RoomMessage(
        userId: _uid, name: _uname, avatar: '',
        text: t.length > 500 ? t.substring(0, 500) : t,
        createdAt: _now));
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
    _roomSub?.cancel(); _partSub?.cancel(); _msgSub?.cancel();
    _roomSub = _partSub = _msgSub = null;
    _hostBeat?.cancel(); _presenceBeat?.cancel();
    _hostBeat = _presenceBeat = null;
    room = null; role = RoomRole.none; participants = const []; messages = const [];
    _joinedAt = null; _wantsControl = false;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() { _disposed = true; _teardown(); super.dispose(); }
}
