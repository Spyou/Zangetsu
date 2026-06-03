import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

import '../playback/hls.dart';

/// Downloads an HLS (m3u8) stream to a single local file by fetching every
/// segment, decrypting AES-128 if needed, and concatenating the raw transport
/// stream into one .mp4 (libmpv/media_kit plays a concatenated TS fine).
///
/// Runs in the Dart isolate (foreground while the app is open) — there's no
/// background_downloader equivalent for segmented HLS. Progress is reported via
/// [onProgress]; [canceled] is polled between segments to abort.
class HlsDownloader {
  HlsDownloader(this._dio);

  final Dio _dio;

  static const int _concurrency = 4; // parallel segment fetches
  static const int _maxAhead = 32; // cap out-of-order buffer (memory bound)

  /// Returns true on success (file written to [outputPath]). On failure or
  /// cancellation the partial file is removed and false is returned.
  Future<bool> download({
    required String url,
    required Map<String, String> headers,
    required String outputPath,
    required String preferredQuality,
    required void Function(double progress) onProgress,
    required bool Function() canceled,
  }) async {
    // 1. Resolve a master playlist down to a media (segment) playlist.
    final media = await _resolveMediaPlaylist(url, headers, preferredQuality);
    if (media == null) return false;
    final mediaUrl = media.$1;
    final playlist = media.$2;

    // 2. Parse segments + (optional) AES-128 key reference.
    final pl = _parseMedia(playlist, mediaUrl);
    if (pl.segments.isEmpty) return false;

    // 3. Fetch the decryption key if the stream is encrypted.
    Uint8List? key;
    if (pl.keyUrl != null) {
      key = await _fetchBytes(pl.keyUrl!, headers);
      if (key == null || key.length != 16) return false; // need a 16-byte key
    }

    // 4. Download segments with bounded parallelism, writing strictly in order.
    final file = File(outputPath);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    final pending = <int, Uint8List>{};
    final total = pl.segments.length;
    var nextIndex = 0;
    var nextWrite = 0;
    var done = 0;
    var failed = false;

    Future<void> worker() async {
      while (true) {
        if (failed || canceled()) return;
        // Throttle so a slow early segment can't blow up the pending buffer.
        while (nextIndex - nextWrite > _maxAhead && !failed && !canceled()) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        if (failed || canceled()) return;
        final i = nextIndex++;
        if (i >= total) return;

        Uint8List? bytes = await _fetchBytes(pl.segments[i], headers);
        if (bytes == null) {
          failed = true;
          return;
        }
        if (key != null) {
          final iv = pl.explicitIv ?? hlsSeqIv(pl.mediaSequence + i);
          bytes = hlsAesCbcDecrypt(bytes, key, iv);
        }
        pending[i] = bytes;
        // Flush every now-contiguous segment (sync, no await → no interleave).
        while (pending.containsKey(nextWrite)) {
          sink.add(pending.remove(nextWrite)!);
          nextWrite++;
          done++;
          onProgress(done / total);
        }
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));
    await sink.flush();
    await sink.close();

    if (failed || canceled() || nextWrite < total) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      return false;
    }
    return true;
  }

  // ── Playlist resolution ───────────────────────────────────────────────────

  /// Follow a master playlist to a media playlist, choosing the variant closest
  /// to [preferredQuality] (or the highest for 'best'/unknown). Returns
  /// (mediaUrl, playlistText).
  Future<(String, String)?> _resolveMediaPlaylist(
    String url,
    Map<String, String> headers,
    String preferredQuality,
  ) async {
    var current = url;
    for (var depth = 0; depth < 3; depth++) {
      final text = await _fetchText(current, headers);
      if (text == null) return null;
      final variants = parseHlsMaster(text, current);
      if (variants.isEmpty) return (current, text); // it's a media playlist
      current = _pickVariant(variants, preferredQuality).url;
    }
    return null;
  }

  HlsVariant _pickVariant(List<HlsVariant> variants, String quality) {
    // variants are already sorted highest-first.
    final want = int.tryParse(
      RegExp(r'(\d{3,4})').firstMatch(quality)?.group(1) ?? '',
    );
    if (quality == 'best' || want == null) return variants.first;
    HlsVariant best = variants.first;
    var bestDelta = 1 << 30;
    for (final v in variants) {
      final h = int.tryParse(RegExp(r'(\d{3,4})').firstMatch(v.quality)?.group(1) ?? '') ?? 0;
      final d = (h - want).abs();
      if (d < bestDelta) {
        bestDelta = d;
        best = v;
      }
    }
    return best;
  }

  _MediaPlaylist _parseMedia(String text, String mediaUrl) {
    final pl = _MediaPlaylist();
    final lines = text.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        pl.mediaSequence = int.tryParse(line.split(':').last.trim()) ?? 0;
      } else if (line.startsWith('#EXT-X-KEY:')) {
        final method = RegExp(r'METHOD=([^,]+)').firstMatch(line)?.group(1) ?? 'NONE';
        if (method.toUpperCase().contains('AES')) {
          final uri = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
          if (uri != null) pl.keyUrl = _resolveRef(uri, mediaUrl);
          final iv = RegExp(r'IV=([0-9A-Fa-fxX]+)').firstMatch(line)?.group(1);
          if (iv != null) pl.explicitIv = hlsParseHexIv(iv);
        }
      } else if (line.startsWith('#EXTINF:')) {
        for (var j = i + 1; j < lines.length; j++) {
          final c = lines[j].trim();
          if (c.isEmpty || c.startsWith('#')) continue;
          pl.segments.add(_resolveRef(c, mediaUrl));
          break;
        }
      }
    }
    return pl;
  }

  // ── HTTP ──────────────────────────────────────────────────────────────────

  Future<String?> _fetchText(String url, Map<String, String> headers) async {
    try {
      final r = await _dio.getUri<String>(
        Uri.parse(url),
        options: Options(
          responseType: ResponseType.plain,
          headers: headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      return r.statusCode == 200 ? r.data : null;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _fetchBytes(String url, Map<String, String> headers) async {
    try {
      final r = await _dio.getUri<List<int>>(
        Uri.parse(url),
        options: Options(
          responseType: ResponseType.bytes,
          headers: headers,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if (r.statusCode != 200 || r.data == null) return null;
      return Uint8List.fromList(r.data!);
    } catch (_) {
      return null;
    }
  }

  static String _resolveRef(String ref, String base) {
    if (ref.startsWith('http://') || ref.startsWith('https://')) return ref;
    return Uri.parse(base).resolve(ref).toString();
  }
}

class _MediaPlaylist {
  final List<String> segments = [];
  String? keyUrl;
  Uint8List? explicitIv;
  int mediaSequence = 0;
}

// ── Crypto helpers (top-level so they're unit-testable) ──────────────────────

/// AES-128-CBC decrypt with PKCS7 unpadding (HLS segment encryption). Returns
/// the input unchanged when it isn't block-aligned.
Uint8List hlsAesCbcDecrypt(Uint8List data, Uint8List key, Uint8List iv) {
  if (data.isEmpty || data.length % 16 != 0) return data;
  final cipher = CBCBlockCipher(AESEngine())
    ..init(false, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
  final out = Uint8List(data.length);
  for (var off = 0; off < data.length; off += 16) {
    cipher.processBlock(data, off, out, off);
  }
  // Strip PKCS7 padding when it's valid (HLS pads each segment).
  final pad = out[out.length - 1];
  if (pad >= 1 && pad <= 16 && pad <= out.length) {
    var valid = true;
    for (var k = out.length - pad; k < out.length; k++) {
      if (out[k] != pad) {
        valid = false;
        break;
      }
    }
    if (valid) return Uint8List.sublistView(out, 0, out.length - pad);
  }
  return out;
}

/// 16-byte big-endian IV from a segment's media-sequence number (the HLS
/// default when no explicit `IV=` is given in the playlist).
Uint8List hlsSeqIv(int seq) {
  final iv = Uint8List(16);
  var v = seq;
  for (var i = 15; i >= 0 && v != 0; i--) {
    iv[i] = v & 0xff;
    v >>= 8;
  }
  return iv;
}

/// Parse an `IV=0x...` hex string into 16 bytes; null if malformed.
Uint8List? hlsParseHexIv(String s) {
  var h = s.trim();
  if (h.startsWith('0x') || h.startsWith('0X')) h = h.substring(2);
  if (h.length != 32) return null;
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    final b = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}
