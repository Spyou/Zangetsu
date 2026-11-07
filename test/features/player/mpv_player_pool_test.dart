import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:watch_app/features/player/mpv_player_pool.dart';

class _Player extends Fake implements Player {
  _Player(this.libass);
  final bool libass;
  int disposals = 0;

  @override
  PlatformPlayer? get platform => null;
  @override
  Future<void> stop() async {}
  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> dispose() async => disposals++;
}

void main() {
  late List<_Player> created;
  late MpvPlayerPool pool;

  setUp(() {
    created = [];
    pool = MpvPlayerPool(
      createPlayer: (libass) {
        final player = _Player(libass);
        created.add(player);
        return player;
      },
    );
  });

  test('uses the untouched prepared player only once', () async {
    pool.warmUp(libass: false);
    pool.warmUp(libass: false);
    expect(created, hasLength(1));
    final first = pool.acquire(libass: false);
    expect(first, same(created.single));
    final second = pool.acquire(libass: false);
    expect(second, isNot(same(first)));
    await pool.clear();
    expect(created.every((p) => p.disposals == 0), isTrue);
  });

  test('a played session is disposed instead of being parked', () async {
    pool.warmUp(libass: false);
    final first = pool.acquire(libass: false) as _Player;
    await first.dispose();
    await pool.clear();
    expect(first.disposals, 1);
    expect(pool.acquire(libass: false), isNot(same(first)));
  });

  test('changed subtitle mode discards the unused prepared player', () async {
    pool.warmUp(libass: false);
    final old = created.single;
    final player = pool.acquire(libass: true) as _Player;
    expect(player.libass, isTrue);
    expect(player, isNot(same(old)));
    expect(old.disposals, 1);
  });

  test('clear frees only the unused preparation and is repeatable', () async {
    pool.warmUp(libass: false);
    await pool.clear();
    await pool.clear();
    expect(created.single.disposals, 1);
  });

  test('failed preparation falls back to a fresh player on acquire', () {
    var calls = 0;
    pool = MpvPlayerPool(
      createPlayer: (libass) {
        if (calls++ == 0) throw StateError('preparation failed');
        return _Player(libass);
      },
    );
    pool.warmUp(libass: false);
    expect(pool.acquire(libass: false), isA<_Player>());
  });
}
