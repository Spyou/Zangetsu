// lib/features/watch_together/watch_together_controller.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../auth/auth_cubit.dart';
import '../../core/di/injector.dart';
import '../../core/ui/global_messenger.dart';
import 'model/room_state.dart';
import 'sync_math.dart';
import 'ui/party_player_route.dart';
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

  /// Navigator key for M3 navigation from outside the widget tree.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Current room mode: 'lobby' when no player is attached, 'playing' when one is.
  String get mode => room?.mode ?? 'lobby';

  /// Bind the controller to the currently-active player. Replaces any prior
  /// binding (only one player is attached at a time). Host marks the room
  /// playing and broadcasts the full content descriptor so viewers know what
  /// to launch; the existing broadcast/heartbeat path takes over from there.
  void attachPlayer({
    required Duration Function() localPosition,
    required void Function(bool playing, Duration pos, double rate) onApplyRemote,
    required void Function(RoomState room) onEpisodeChange,
    Map<String, dynamic>? content,
  }) {
    this.localPosition = localPosition;
    this.onApplyRemote = onApplyRemote;
    this.onEpisodeChange = onEpisodeChange;
    if (isHost) _writeHost(extra: {'mode': 'playing', ...?content});
  }

  /// Unbind on player close. Host returns the room to the lobby (idle) state.
  void detachPlayer() {
    localPosition = null;
    onApplyRemote = null;
    onEpisodeChange = null;
    if (isHost && room != null) _writeHost(extra: {'mode': 'lobby'});
  }

  StreamSubscription<RoomState>? _roomSub;
  StreamSubscription<void>? _partSub;
  StreamSubscription<RoomMessage>? _msgSub;
  Timer? _hostBeat;
  String? _lastEpisodeId;
  int? _joinedAt;
  bool _wantsControl = false;
  bool _disposed = false;

  // Viewer follow-navigation state (unused for the host).
  String? _viewerStageKey;
  bool _viewerPlayerUp = false;

  String get _uid => sl<AuthCubit>().state.user?.id ?? '';
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
      final code = r?.code;
      final pos = localPosition?.call();
      if (r != null && code != null && r.playing && pos != null) {
        // Zero-write heartbeat: Broadcast only, never updateRoom.
        _svc.broadcastHostState(code,
            posMs: pos.inMilliseconds, rate: r.rate, playing: r.playing);
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
    // Presence: track once on enter. No re-upsert beat — Supabase Realtime
    // maintains liveness automatically and drops us from the roster on
    // socket disconnect (crash/close), which _refreshParticipants below then
    // observes via watchParticipants ticks.
    await _svc.upsertParticipant(code, RoomParticipant(
        userId: _uid, name: _uname, avatar: '', state: 'watching',
        joinedAt: _joinedAt ?? _now, lastSeenAt: _now,
        wantsControl: _wantsControl));
    _subscribeRoom(code);
    _partSub = _svc.watchParticipants(code).listen((_) => _refreshParticipants(code));
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
    _maybePromoteSelf(); // crash-failover check — driven by presence ticks now
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
    if (!isHost) {
      _applyRoom(r);
      _followHost(r);
    }
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

  /// Play/pause/seek/episode/mode/host-transfer anchor writes — these are
  /// discrete, user-driven events (not the 4s beat), so a `watch_rooms` row
  /// update here is the "pause-stop anchor" the design calls for: late
  /// joiners and reconnects seed off this row via getRoom/postgres_changes.
  /// The row's `content` column mirrors the full RoomState.toMap(), so we
  /// merge [extra] onto the current state's map wholesale (same shape [extra]
  /// always had pre-migration) rather than threading every field through
  /// copyWith — JSONB has no server-side partial merge without an RPC.
  void _writeHost({bool? playing, int? positionMs, Map<String, dynamic>? extra}) {
    final r = room;
    final code = r?.code;
    if (r == null || code == null) return;
    final map = <String, dynamic>{...r.toMap(), ...?extra, 'updatedAt': _now};
    if (playing != null) map['playing'] = playing;
    if (positionMs != null) map['positionMs'] = positionMs;
    final updated = RoomState.fromMap(map);
    room = updated;
    // Broadcast immediately for instant peer sync; the row write below is
    // the anchor for late joiners/reconnects (postgres_changes latency is
    // fine for that path — it's not what drives live playback sync).
    _svc.broadcastHostState(code,
        posMs: updated.positionMs, rate: updated.rate, playing: updated.playing);
    _svc.updateRoom(code, {
      'content': map,
      'host_key': updated.hostId,
      'host_pos_ms': updated.positionMs,
      'host_rate': updated.rate,
      'host_playing': updated.playing,
      'status': updated.status,
    });
  }

  // ---- migration ----
  void _maybePromoteSelf() {
    final r = room; if (r == null || isHost) return;
    // Presence (not a lastSeenAt beat) is now the liveness signal: a crashed
    // or closed host is untracked by the Realtime socket and vanishes from
    // the roster, so absence IS staleness — no periodic re-upsert needed.
    final hostStale = !participants.any((p) => p.userId == r.hostId);
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

  // ---- viewer follow-navigation ----

  /// Drives the viewer's navigator to follow the host's current stage:
  /// - host playing a show  → push (or replace) the content player
  /// - host goes idle       → pop back to the HostChoosingScreen base
  ///
  /// Keyed on the SHOW (sourceId|showUrl), not the episode, so that episode
  /// switches within the same loaded show are handled in-place by [onEpisodeChange]
  /// and do NOT cause an extra push here.
  void _followHost(RoomState r) {
    final target = (r.mode == 'playing' && r.sourceId.isNotEmpty)
        ? '${r.sourceId}|${r.showUrl}'
        : null;
    if (target == _viewerStageKey) return;
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    _viewerStageKey = target;
    if (target != null) {
      final route = buildPartyPlayerRoute(r);
      if (_viewerPlayerUp) {
        nav.pushReplacement(route);
      } else {
        nav.push(route);
        _viewerPlayerUp = true;
      }
    } else if (_viewerPlayerUp) {
      nav.pop(); // back to the HostChoosingScreen base
      _viewerPlayerUp = false;
    }
  }

  /// Re-run the viewer follow for the CURRENT room once (used right after the
  /// lobby pushes the HostChoosingScreen base, so the player lands ON TOP of it
  /// when the host is already playing). Resetting the stage key first defeats
  /// the dedup so the initial follow is not swallowed.
  void refollow() {
    _viewerStageKey = null;
    final r = room;
    if (r != null && !isHost) _followHost(r);
  }

  Future<void> leave() async {
    final code = room?.code;
    if (code != null && isHost) {
      final successor = electSuccessor(participants, leavingHostId: _uid, nowMs: _now);
      final r = room;
      if (successor != null && r != null) {
        final updated = r.copyWith(hostId: successor);
        await _svc.updateRoom(code, {
          'content': updated.toMap(),
          'host_key': successor,
        });
      } else {
        final updated = r?.copyWith(status: 'ended');
        await _svc.updateRoom(code, {
          if (updated != null) 'content': updated.toMap(),
          'status': 'ended',
        });
      }
    }
    if (code != null) {
      await _svc.removeParticipant(code, _uid);
      _svc.closeChannel(code);
    }
    if (_viewerPlayerUp) {
      rootNavigatorKey.currentState?.pop();
      _viewerPlayerUp = false;
      _viewerStageKey = null;
    }
    _teardown();
  }

  void _teardown() {
    _roomSub?.cancel(); _partSub?.cancel(); _msgSub?.cancel();
    _roomSub = _partSub = _msgSub = null;
    _hostBeat?.cancel();
    _hostBeat = null;
    room = null; role = RoomRole.none; participants = const []; messages = const [];
    _joinedAt = null; _wantsControl = false;
    _viewerStageKey = null; _viewerPlayerUp = false;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() { _disposed = true; _teardown(); super.dispose(); }
}
