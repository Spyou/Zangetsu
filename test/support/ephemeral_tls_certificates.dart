import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Creates disposable localhost TLS identities using the Android build JDK.
///
/// Keys and keystore passwords exist only in a temporary directory/memory for
/// this test run. No private key or fixed password is checked into source.
class EphemeralTlsCertificates {
  EphemeralTlsCertificates._(this.directory, this.password);

  /// Directory owned by this test run, outside the repository.
  final Directory directory;

  /// Random, test-only protection for this run's PKCS12 containers.
  final String password;

  /// Public test CA used by the client; its private key stays in the temp store.
  File get rootCertificate => File('${directory.path}/root.pem');

  /// Generates one trusted server, one untrusted server, and one wrong-host peer.
  static Future<EphemeralTlsCertificates> create() async {
    final random = Random.secure();
    final password = base64UrlEncode(
      List<int>.generate(24, (_) => random.nextInt(256)),
    );
    final directory = await Directory.systemTemp.createTemp('AniAura-tls-');
    final certificates = EphemeralTlsCertificates._(directory, password);
    try {
      await certificates._generate('root', ca: true);
      await certificates._keytool([
        '-exportcert',
        '-rfc',
        '-alias',
        'root',
        '-keystore',
        '${directory.path}/root.p12',
        '-file',
        certificates.rootCertificate.path,
      ]);
      await certificates._generate('untrusted');
      for (final name in ['server', 'wrong_host']) {
        await certificates._generate(name);
        final store = '${directory.path}/$name.p12';
        final request = '${directory.path}/$name.csr';
        final signed = '${directory.path}/$name.pem';
        await certificates._keytool([
          '-certreq',
          '-alias',
          name,
          '-keystore',
          store,
          '-file',
          request,
        ]);
        await certificates._keytool([
          '-gencert',
          '-rfc',
          '-alias',
          'root',
          '-keystore',
          '${directory.path}/root.p12',
          '-infile',
          request,
          '-outfile',
          signed,
          '-validity',
          '2',
          '-ext',
          name == 'server'
              ? 'SAN=DNS:localhost,IP:127.0.0.1'
              : 'SAN=DNS:wrong.invalid',
          '-ext',
          'EKU=serverAuth',
        ]);
        await certificates._keytool([
          '-importcert',
          '-noprompt',
          '-alias',
          'root',
          '-keystore',
          store,
          '-file',
          certificates.rootCertificate.path,
        ]);
        await certificates._keytool([
          '-importcert',
          '-noprompt',
          '-alias',
          name,
          '-keystore',
          store,
          '-file',
          signed,
        ]);
      }
      return certificates;
    } catch (_) {
      await certificates.dispose();
      rethrow;
    }
  }

  /// Loads the selected ephemeral identity without exporting its private key.
  SecurityContext serverContext(String name) {
    final store = '${directory.path}/$name.p12';
    return SecurityContext()
      ..useCertificateChain(store, password: password)
      ..usePrivateKey(store, password: password);
  }

  /// Removes only the temporary directory created and owned by this helper.
  Future<void> dispose() async {
    final root = Directory.systemTemp.absolute.path;
    final target = directory.absolute.path;
    final basename = directory.uri.pathSegments
        .where((part) => part.isNotEmpty)
        .last;
    if (!target.startsWith('$root${Platform.pathSeparator}') ||
        !basename.startsWith('AniAura-tls-')) {
      throw StateError(
        'Refusing to remove a directory outside the TLS test temp area',
      );
    }
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  /// Issues a fresh keypair inside an encrypted, temporary PKCS12 container.
  Future<void> _generate(String name, {bool ca = false}) => _keytool([
    '-genkeypair',
    '-noprompt',
    '-alias',
    name,
    '-keystore',
    '${directory.path}/$name.p12',
    '-storetype',
    'PKCS12',
    '-keyalg',
    'RSA',
    '-keysize',
    '2048',
    '-dname',
    'CN=AniAura TLS test $name',
    '-validity',
    '2',
    '-keypass',
    password,
    '-ext',
    ca ? 'BC=ca:true' : 'SAN=DNS:localhost,IP:127.0.0.1',
  ]);

  /// Runs the existing JDK's keytool without logging passwords or key material.
  Future<void> _keytool(List<String> arguments) async {
    final javaHome = Platform.environment['JAVA_HOME'];
    final executable = javaHome == null
        ? 'keytool'
        : '$javaHome/bin/keytool${Platform.isWindows ? '.exe' : ''}';
    final result = await Process.run(executable, [
      ...arguments,
      '-storepass',
      password,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'TLS test certificate generation failed: ${result.stderr}',
      );
    }
  }
}
