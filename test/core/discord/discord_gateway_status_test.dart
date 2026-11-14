import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/discord/discord_gateway.dart';
import 'package:watch_app/core/discord/discord_presence.dart';

class _Gateway extends DiscordGateway {
  _Gateway() : super('test');
  final statuses = <String>[];

  @override
  void setPresence(DiscordActivity? activity, {String status = 'online'}) {
    statuses.add(status);
    super.setPresence(activity, status: status);
  }
}

void main() {
  for (final status in ['online', 'idle', 'dnd', 'invisible']) {
    test('closing the desktop transport preserves $status', () async {
      final gateway = _Gateway();
      gateway.setPresence(const DiscordActivity(name: 'Title'), status: status);
      await gateway.clearThenClose();
      expect(gateway.statuses, [status, status]);
    });
  }
}
