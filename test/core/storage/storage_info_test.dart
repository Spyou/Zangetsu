import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/storage/storage_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('AniAura/storage');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('returns free bytes from the native side', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'freeBytes');
          return 12345;
        });

    expect(await StorageInfo.freeBytes(), 12345);
  });

  test('a missing channel reads as unknown, never zero', () async {
    expect(await StorageInfo.freeBytes(), isNull);
  });

  test('a native failure reads as unknown', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'boom');
        });

    expect(await StorageInfo.freeBytes(), isNull);
  });

  test('zero free bytes means full storage, not an unknown volume', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => 0);
    expect(await StorageInfo.freeBytes(), 0);
  });

  test('passes the selected drive and private-storage choice to Android', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.arguments, {
            'destination':
                'content://com.android.externalstorage.documents/tree/ABCD%3ADownloads',
            'privateStorage': false,
          });
          return 99;
        });
    expect(
      await StorageInfo.freeBytes(
        destination:
            'content://com.android.externalstorage.documents/tree/ABCD%3ADownloads',
      ),
      99,
    );
  });
}
