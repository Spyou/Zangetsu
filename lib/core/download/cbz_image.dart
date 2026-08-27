import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Marks a page that lives inside a `.cbz` rather than as a loose file:
/// `cbz:/path/to/Chapter 1.cbz#3`.
///
/// The reader gets page URLs as plain strings, so the archive and the page
/// index have to travel as one.
const String cbzScheme = 'cbz:';

String cbzUrl(String archivePath, int index) =>
    '$cbzScheme$archivePath#$index';

/// One page out of a `.cbz`.
///
/// Pages are stored uncompressed, so pulling one out is a seek and a copy
/// rather than a decompress — cheap enough to do per page instead of unpacking
/// the whole chapter to disk first.
@immutable
class CbzImage extends ImageProvider<CbzImage> {
  const CbzImage(this.archivePath, this.index, {this.scale = 1.0});

  /// Parses a `cbz:` url back into a provider, or null if it isn't one.
  static CbzImage? tryParse(String url) {
    if (!url.startsWith(cbzScheme)) return null;
    final rest = url.substring(cbzScheme.length);
    final hash = rest.lastIndexOf('#');
    if (hash <= 0) return null;
    final index = int.tryParse(rest.substring(hash + 1));
    if (index == null) return null;
    return CbzImage(rest.substring(0, hash), index);
  }

  final String archivePath;
  final int index;
  final double scale;

  @override
  Future<CbzImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CbzImage>(this);

  @override
  ImageStreamCompleter loadImage(CbzImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(key, decode),
        scale: key.scale,
        debugLabel: '$cbzScheme$archivePath#$index',
      );

  Future<ui.Codec> _load(CbzImage key, ImageDecoderCallback decode) async {
    final bytes = await _readEntry(key.archivePath, key.index);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Page ${key.index} missing from ${key.archivePath}');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is CbzImage &&
      other.archivePath == archivePath &&
      other.index == index &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(archivePath, index, scale);

  @override
  String toString() => 'CbzImage("$archivePath", $index)';
}

/// The last archive opened, kept around so scrolling a chapter doesn't reparse
/// its central directory on every page. One entry is enough — a reader only
/// ever has one chapter open.
String? _openPath;
Archive? _openArchive;
InputFileStream? _openStream;

Future<Uint8List?> _readEntry(String path, int index) async {
  if (_openPath != path) {
    _closeOpen();
    if (!File(path).existsSync()) return null;
    final stream = InputFileStream(path);
    try {
      _openArchive = ZipDecoder().decodeStream(stream);
      _openStream = stream;
      _openPath = path;
    } catch (_) {
      await stream.close();
      return null;
    }
  }
  final archive = _openArchive;
  if (archive == null) return null;
  // Zip order is the order they were added, which is page order — but sort
  // defensively so a rewritten archive can't shuffle the chapter.
  final files = archive.files.where((f) => f.isFile).toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  if (index < 0 || index >= files.length) return null;
  return files[index].readBytes();
}

void _closeOpen() {
  _openStream?.closeSync();
  _openStream = null;
  _openArchive = null;
  _openPath = null;
}

/// Page count without unpacking anything — used to build the reader's page
/// list from a saved chapter.
Future<int> cbzPageCount(String path) async {
  if (!await File(path).exists()) return 0;
  final stream = InputFileStream(path);
  try {
    return ZipDecoder()
        .decodeStream(stream)
        .files
        .where((f) => f.isFile)
        .length;
  } catch (_) {
    return 0;
  } finally {
    await stream.close();
  }
}

/// Drops the cached handle — call before deleting an archive so the file isn't
/// still open underneath it.
void releaseCbz() => _closeOpen();
