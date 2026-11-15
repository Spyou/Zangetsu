import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'stremio_configuration_merge.dart';
import 'stremio_manager.dart';
import 'stremio_remote.dart';

class StremioSync extends ChangeNotifier {
  StremioSync({
    required StremioManager manager,
    required StremioRemote remote,
    StremioSecretStore secrets = const StremioSecureStore(),
  }) : _manager = manager,
       _remote = remote,
       _secrets = secrets {
    _manager.addListener(_onChanged);
  }
  final StremioManager _manager;
  final StremioRemote _remote;
  final StremioSecretStore _secrets;
  String? _owner;
  String? _desired;
  String? get owner => _owner;
  String? lastError;
  Map<String, dynamic>? _base;
  bool _initialized = false;
  bool _applying = false;
  bool _disposed = false;
  int _generation = 0;
  Future<void> _writes = Future.value();
  final _requests = <int, Future<void>>{};
  StreamSubscription<String?>? _accounts;
  Timer? _timer;
  DateTime? _lastSync;
  static const _ownerKey = 'stremio:sync:owner';
  String _stateKey(String? owner) => 'stremio:sync:state:${owner ?? 'guest'}';

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  void start(String? initialOwner, Stream<String?> accounts) {
    unawaited(setAccount(initialOwner));
    _accounts = accounts.distinct().listen(
      (owner) => unawaited(setAccount(owner)),
    );
  }

  bool _current(int generation) =>
      !_disposed &&
      _initialized &&
      _generation == generation &&
      _owner == _desired;

  Future<void> setAccount(String? account) async {
    if (_initialized && _owner == account && _desired == account) {
      return refresh();
    }
    _desired = account;
    final generation = ++_generation;
    _timer?.cancel();
    try {
      await _serial(() async {
        if (_disposed || generation != _generation) return;
        if (!_initialized) {
          final rawOwner = await _secrets.read(_ownerKey);
          final marker = rawOwner == null ? null : jsonDecode(rawOwner) as Map;
          _owner = marker == null ? account : marker['owner'] as String?;
          final cached = await _readState(_owner);
          if (marker?.containsKey('switchingTo') == true) {
            if (cached?['configuration'] is! Map) throw const FormatException();
            _applying = true;
            try {
              await _manager.restoreConfiguration(
                Map<String, dynamic>.from(cached!['configuration'] as Map),
                merge: false,
              );
              await _secrets.write(_ownerKey, jsonEncode({'owner': _owner}));
            } finally {
              _applying = false;
            }
          }
          _base = cached?['base'] == null
              ? null
              : Map<String, dynamic>.from(cached!['base'] as Map);
          _initialized = true;
        }
        if (_owner != account) {
          Map<String, dynamic>? cached;
          _applying = true;
          try {
            await _manager.transitionConfiguration(
              prepare: (previous) async {
                await _persist(previous);
                cached = await _readState(account);
                await _secrets.write(
                  _ownerKey,
                  jsonEncode({'owner': _owner, 'switchingTo': account}),
                );
                return {
                  ...(cached?['configuration'] == null
                      ? emptyStremioConfiguration()
                      : Map<String, dynamic>.from(
                          cached!['configuration'] as Map,
                        )),
                  'seedDefault': cached == null,
                };
              },
              commit: () =>
                  _secrets.write(_ownerKey, jsonEncode({'owner': account})),
              rollback: () =>
                  _secrets.write(_ownerKey, jsonEncode({'owner': _owner})),
            );
          } catch (_) {
            _initialized = false;
            rethrow;
          } finally {
            _applying = false;
          }
          _owner = account;
          _base = cached?['base'] == null
              ? null
              : Map<String, dynamic>.from(cached!['base'] as Map);
        } else {
          await _secrets.write(_ownerKey, jsonEncode({'owner': account}));
        }
        _lastSync = null;
        lastError = null;
        await _persist(await _manager.exportConfiguration());
      });
      if (_current(generation)) await refresh();
    } catch (_) {
      _failed();
    }
  }

  Future<Map<String, dynamic>?> _readState(String? owner) async {
    final raw = await _secrets.read(_stateKey(owner));
    if (raw == null) return null;
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<void> _persist(Map<String, dynamic> configuration) => _secrets.write(
    _stateKey(_owner),
    jsonEncode({'base': _base, 'configuration': configuration}),
  );

  void _onChanged() {
    if (_applying || _disposed || !_initialized) return;
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(refresh()),
    );
  }

  Future<void> refresh({Duration maxAge = Duration.zero}) {
    if (_disposed) return Future.value();
    if (!_initialized || _desired != _owner) return setAccount(_desired);
    if (_lastSync != null && DateTime.now().difference(_lastSync!) < maxAge) {
      return Future.value();
    }
    final generation = _generation;
    return _requests.putIfAbsent(generation, () {
      final request = _sync(generation);
      unawaited(request.whenComplete(() => _requests.remove(generation)));
      return request;
    });
  }

  Future<void> _sync(int generation) async {
    try {
      final account = _owner;
      await _serial(() async {
        if (_current(generation)) {
          await _persist(await _manager.exportConfiguration());
        }
      });
      if (!_current(generation) || account == null) return;
      var saved = await _remote.request(account, 'configuration', {});
      for (var attempt = 0; attempt < 3; attempt++) {
        if (!_current(generation)) return;
        final remote = saved['configuration'] == null
            ? emptyStremioConfiguration()
            : Map<String, dynamic>.from(saved['configuration'] as Map);
        final local = await _manager.exportConfiguration();
        final revision = _manager.revision;
        if (!_current(generation)) return;
        final merged = mergeStremioConfiguration(_base, local, remote);
        if (!stremioConfigurationsEqual(merged, remote)) {
          saved = await _remote.request(account, 'configuration', {
            'expectedVersion': saved['version'],
            'configuration': merged,
          });
          if (saved['accepted'] != true) continue;
        }
        final accepted = saved['configuration'] == null
            ? merged
            : Map<String, dynamic>.from(saved['configuration'] as Map);
        await _serial(() async {
          if (!_current(generation)) return;
          final comparable = Map<String, dynamic>.from(accepted)
            ..remove('deleted');
          if (_manager.revision == revision &&
              !stremioConfigurationsEqual(local, comparable)) {
            _applying = true;
            try {
              await _manager.restoreConfiguration(
                accepted,
                merge: false,
                expectedRevision: revision,
              );
            } finally {
              _applying = false;
            }
          } else if (_manager.revision != revision) {
            _timer?.cancel();
            _timer = Timer(
              const Duration(milliseconds: 500),
              () => unawaited(refresh()),
            );
          }
          _base = accepted;
          await _persist(await _manager.exportConfiguration());
          lastError = null;
          _lastSync = DateTime.now();
          if (!_disposed) notifyListeners();
        });
        return;
      }
      if (_current(generation)) _failed();
    } catch (_) {
      if (_current(generation)) _failed();
    }
  }

  void _failed() {
    if (_disposed) return;
    lastError =
        'Addon sync needs a retry. Local addon settings are kept on this device.';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    unawaited(_accounts?.cancel());
    _manager.removeListener(_onChanged);
    super.dispose();
  }
}
