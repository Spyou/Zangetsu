import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// A page held open by the native side. [ptr] is opaque — only this library
/// may touch it.
class TileHandle {
  TileHandle(this.ptr, this.width, this.height);

  final Pointer<Void> ptr;
  final int width;
  final int height;
}

/// One decoded tile. [stride] is the real row length in bytes and can exceed
/// `width * 4`, because the decoder aligns rows. Reading with `width * 4`
/// draws the tile skewed diagonally.
class TileBytes {
  TileBytes(this.rgba, this.stride, this.width, this.height);

  final Uint8List rgba;
  final int stride;
  final int width;
  final int height;
}

typedef _AvailableC = Int32 Function();
typedef _AvailableDart = int Function();

typedef _OpenC = Pointer<Void> Function(
    Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>);
typedef _OpenDart = Pointer<Void> Function(
    Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>);

typedef _DecodeC = Bool Function(Pointer<Void>, Int32, Int32, Int32, Int32,
    Int32, Pointer<Uint8>, Int32, Pointer<Int32>);
typedef _DecodeDart = bool Function(Pointer<Void>, int, int, int, int, int,
    Pointer<Uint8>, int, Pointer<Int32>);

typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

final DynamicLibrary _lib = Platform.isAndroid
    ? DynamicLibrary.open('libtile_decoder.so')
    : DynamicLibrary.process();

final _available = _lib.lookupFunction<_AvailableC, _AvailableDart>(
  'tile_available',
);
final _open = _lib.lookupFunction<_OpenC, _OpenDart>('tile_open');
final _decode = _lib.lookupFunction<_DecodeC, _DecodeDart>('tile_decode');
final _close = _lib.lookupFunction<_CloseC, _CloseDart>('tile_close');

bool _probed = false;
bool _usable = false;

/// Whether this device can decode regions at all. Checked once: the answer
/// cannot change while the app runs, and on Android below API 30 it is no.
bool tileDecodingAvailable() {
  if (_probed) return _usable;
  _probed = true;
  try {
    _usable = _available() == 1;
  } catch (_) {
    // The library is missing or the symbol is not there — treat as unusable
    // rather than letting it throw into the reader.
    _usable = false;
  }
  return _usable;
}

TileHandle? tileOpen(String path) {
  if (!tileDecodingAvailable()) return null;
  final cPath = path.toNativeUtf8();
  final wPtr = calloc<Int32>();
  final hPtr = calloc<Int32>();
  try {
    final ptr = _open(cPath, wPtr, hPtr);
    if (ptr == nullptr) return null;
    return TileHandle(ptr, wPtr.value, hPtr.value);
  } finally {
    calloc.free(cPath);
    calloc.free(wPtr);
    calloc.free(hPtr);
  }
}

TileBytes? tileDecode(
  TileHandle handle,
  int x,
  int y,
  int width,
  int height,
  int sample,
) {
  if (width <= 0 || height <= 0 || sample < 1) return null;
  // Generous: the native side reports the stride it actually used, and a row
  // may be padded beyond width * 4.
  final capacity = (width + 16) * 4 * height;
  final buffer = calloc<Uint8>(capacity);
  final stridePtr = calloc<Int32>();
  try {
    final ok = _decode(
      handle.ptr,
      x,
      y,
      width,
      height,
      sample,
      buffer,
      capacity,
      stridePtr,
    );
    if (!ok) return null;
    final stride = stridePtr.value;
    final bytes = Uint8List.fromList(
      buffer.asTypedList(stride * height),
    );
    return TileBytes(bytes, stride, width, height);
  } finally {
    calloc.free(buffer);
    calloc.free(stridePtr);
  }
}

void tileClose(TileHandle handle) {
  if (!tileDecodingAvailable()) return;
  _close(handle.ptr);
}
