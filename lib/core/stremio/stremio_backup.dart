import 'stremio_backup_cipher.dart';
import 'stremio_manager.dart';
import 'stremio_remote.dart';

class StremioBackup {
  StremioBackup({
    required StremioManager manager,
    required StremioRemote remote,
    required String? Function() currentUserId,
  }) : _manager = manager,
       _remote = remote,
       _currentUserId = currentUserId;
  final StremioManager _manager;
  final StremioRemote _remote;
  final String? Function() _currentUserId;

  Future<Map<String, dynamic>> encode({
    String? password,
    bool forFile = false,
  }) async {
    final owner = _currentUserId();
    final configuration = await _manager.exportConfiguration();
    final Map<String, dynamic> envelope;
    if (forFile) {
      if (password == null) {
        throw const StremioBackupException(
          'Choose a password to protect addon URLs.',
        );
      }
      envelope = await StremioBackupCipher.encrypt(configuration, password);
    } else {
      if (owner == null) {
        throw const StremioBackupException('Sign in to back up addons.');
      }
      envelope = await _remote.request(owner, 'seal', {
        'configuration': configuration,
      });
    }
    if (_currentUserId() != owner) {
      throw const StremioBackupException(
        'Account changed. Please retry the backup.',
      );
    }
    return envelope;
  }

  Future<Map<String, dynamic>> decode(
    Map<String, dynamic> envelope, {
    String? password,
  }) async {
    if (envelope['format'] == StremioBackupCipher.format) {
      if (password == null) {
        throw const StremioBackupException('Enter the addon backup password.');
      }
      return StremioBackupCipher.decrypt(envelope, password);
    }
    if (envelope['format'] != 'stremio-server-v1') {
      throw const StremioBackupException('Unsupported addon backup format.');
    }
    final owner = _currentUserId();
    if (owner == null) {
      throw const StremioBackupException(
        'Sign in to the account that created this addon backup.',
      );
    }
    final response = await _remote.request(owner, 'open', {
      'envelope': envelope,
    });
    return Map<String, dynamic>.from(response['configuration'] as Map);
  }

  Future<void> validate(Map<String, dynamic> configuration) =>
      _manager.restoreConfiguration(configuration, validateOnly: true);
  Future<void> Function(Map<String, dynamic>) guardedRestore() {
    final owner = _currentUserId();
    final revision = _manager.revision;
    return (configuration) async {
      if (_currentUserId() != owner) {
        throw const StremioBackupException(
          'Account changed. Please retry the restore.',
        );
      }
      await _manager.restoreConfiguration(
        configuration,
        expectedRevision: revision,
      );
    };
  }
}
