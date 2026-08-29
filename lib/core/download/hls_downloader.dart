import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

import '../playback/hls.dart';

/// Downloads an HLS (m3u8) stream to a single local file by fetching every
/// segment, decrypting AES-128 if needed, and concatenating into one .mp4.
/// Handles both flavors: plain TS segments (concatenated directly) and fMP4
/// (`#EXT-X-MAP` init segment written first, then the `.m4s` fragments) — libmpv
/// plays either a concatenated TS or a concatenated fragmented-MP4 fine.
///
/// Runs in the Dart isolate (foreground while the app is open) — there's no
/// background_downloader equivalent for segmented HLS. Progress is reported via
/// [onProgress]; [canceled] is polled between segments to abort.
class HlsDownloader {
  HlsDownloader(this._dio);

  final Dio _dio;

  static const int _concurrency = 4; // parallel segment fetches
  static const int _maxAhead = 32; // cap out-of-order buffer (memory bound)

  /// Returns null on success (file written to [outputPath]). On failure or
  /// cancellation the partial file is removed and a short reason string is
  /// returned — surfaced on the download tile and logged by the manager, so a
  /// failed HLS download is no longer a silent black box.
  Future<String?> download({
    required String url,
    required Map<String, String> headers,
    required String outputPath,
    required String preferredQuality,
    required void Function(double progress) onProgress,
    required bool Function() canceled,
    int? connections,
  }) async {
    // Segment-fetch parallelism for THIS download (clamped); defaults to 4.
    final concurrency = (connections ?? _concurrency).clamp(1, _concurrency * 4);
    // 1. Resolve a master playlist down to a media (segment) playlist.
    final media = await _resolveMediaPlaylist(url, headers, preferredQuality);
    if (media == null) return 'playlist unreachable';
    final mediaUrl = media.$1;
    final playlist = media.$2;

    // 2. Parse segments + (optional) AES-128 key reference.
    final pl = _parseMedia(playlist, mediaUrl);
    if (pl.segments.isEmpty) return 'empty playlist (no segments)';

    // 3. Fetch the decryption key if the stream is encrypted.
    Uint8List? key;
    if (pl.keyUrl != null) {
      key = await _fetchBytes(pl.keyUrl!, headers);
      if (key == null || key.length != 16) return 'AES key fetch failed';
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
    String? failReason;

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
          failReason ??= 'segment ${i + 1}/$total unreachable';
          return;
        }
        if (key != null) {
          final iv = pl.explicitIv ?? hlsSeqIv(pl.mediaSequence + i);
          bytes = hlsAesCbcDecrypt(bytes, key, iv);
        }
        // TS segments only (fMP4 has an init header and no 0x47 sync): drop any
        // decoy prefix so the saved file is clean TS external players can demux.
        if (pl.initUrl == null) bytes = hlsStripToTsSync(bytes);
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

    // fMP4: write the init segment FIRST so the file has its ftyp+moov header
    // before the moof+mdat fragments — otherwise the result is unplayable. TS
    // playlists have no `#EXT-X-MAP`, so initUrl is null and this is skipped
    // (TS downloads are unchanged). The init segment is never encrypted.
    if (pl.initUrl != null) {
      final init = await _fetchBytes(pl.initUrl!, headers);
      if (init == null) {
        await sink.close();
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        return 'init segment fetch failed';
      }
      sink.add(init);
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    await sink.flush();
    await sink.close();

    if (failed || canceled() || nextWrite < total) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      if (canceled()) return 'canceled';
      return failReason ?? 'incomplete ($nextWrite/$total segments)';
    }
    return null;
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
      } else if (line.startsWith('#EXT-X-MAP:')) {
        // fMP4 init segment — must be written before any fragment. (We don't
        // handle BYTERANGE inits, rare; the common case is a full init file.)
        final uri = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
        if (uri != null) pl.initUrl = _resolveRef(uri, mediaUrl);
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

  /// fMP4 initialization segment (`#EXT-X-MAP:URI="…"`) — the ftyp+moov header
  /// the `.m4s` fragments lack. Null for plain TS playlists.
  String? initUrl;
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

/// Strip a decoy/junk prefix that some anti-scrape CDNs prepend to each TS
/// segment (e.g. a 1×1 PNG + "Service01" marker sitting before the real
/// stream). MPEG-TS is 188-byte packets each starting with sync byte 0x47;
/// find the first offset that is 0x47 AND is 0x47 again one and two packets
/// later — a real packet boundary, not a stray match — and return the bytes
/// from there. A clean segment already starts at a valid boundary, so this
/// returns it UNCHANGED (offset 0); when no aligned sync is found within a
/// small window (non-TS data, or an unusually large prefix) it also returns the
/// input untouched, so it can never corrupt a normal download.
Uint8List hlsStripToTsSync(Uint8List seg) {
  const ts = 188;
  if (seg.length < ts * 3) return seg; // too short to validate — leave alone
  // A real decoy prefix is tiny (tens/hundreds of bytes). Bound the scan so we
  // find it near the start and never match a coincidental 0x47 deep in payload.
  final maxStart = seg.length - ts * 2;
  final scanEnd = maxStart < 4096 ? maxStart : 4096;
  for (var i = 0; i < scanEnd; i++) {
    if (seg[i] == 0x47 && seg[i + ts] == 0x47 && seg[i + ts * 2] == 0x47) {
      return i == 0 ? seg : Uint8List.sublistView(seg, i);
    }
  }
  return seg; // no aligned TS sync near the start — don't touch it
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

/// First non-comment URI line in an HLS playlist (variant or segment).
String? hlsFirstUriLine(String playlist) {
  var expectUri = false;
  for (final raw in playlist.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final upper = line.toUpperCase();
    if (upper.startsWith('#EXT-X-I-FRAME-STREAM-INF')) continue;
    if (upper.startsWith('#EXT-X-STREAM-INF') || upper.startsWith('#EXTINF')) {
      expectUri = true;
      continue;
    }
    if (line.startsWith('#')) continue;
    if (expectUri) return line;
  }
  // Media playlists sometimes omit a recognizable tag before the first URI.
  for (final raw in playlist.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    return line;
  }
  return null;
}

bool hlsPlaylistIsMaster(String playlist) =>
    playlist.contains('#EXT-X-STREAM-INF');

bool hlsPlaylistIsEncrypted(String playlist) {
  final u = playlist.toUpperCase();
  return u.contains('#EXT-X-KEY:METHOD=AES-128') ||
      u.contains('#EXT-X-KEY:METHOD=SAMPLE-AES');
}

/// Peel a decoy image/junk prefix off a disguised HLS segment (`.jpg` / PNG
/// wrappers used by some CDNs). Scans the fetched prefix for MPEG-TS sync or
/// an ISO-BMFF `ftyp`/`moof` box. Returns null if neither is found.
Uint8List? hlsUnwrapSegment(Uint8List seg, {int scanLimit = 128 * 1024}) {
  if (seg.length < 12) return seg;
  if (seg[0] == 0x47 && _hasTsSync(seg, 188, 0)) return seg;
  if (isoLooksLikeFmp4(seg)) return seg;
  final limit = seg.length < scanLimit ? seg.length : scanLimit;
  const ts = 188;
  final tsEnd = limit - ts * 3;
  for (var i = 1; i <= tsEnd; i++) {
    if (seg[i] == 0x47 &&
        seg[i + ts] == 0x47 &&
        seg[i + ts * 2] == 0x47 &&
        (i + ts * 3 >= seg.length || seg[i + ts * 3] == 0x47)) {
      return Uint8List.sublistView(seg, i);
    }
  }
  for (var i = 4; i + 8 <= limit; i++) {
    final a = seg[i], b = seg[i + 1], c = seg[i + 2], d = seg[i + 3];
    final ftyp = a == 0x66 && b == 0x74 && c == 0x79 && d == 0x70; // ftyp
    final styp = a == 0x73 && b == 0x74 && c == 0x79 && d == 0x70; // styp
    final moof = a == 0x6d && b == 0x6f && c == 0x6f && d == 0x66; // moof
    if (ftyp || styp || moof) {
      return Uint8List.sublistView(seg, i - 4);
    }
  }
  return null;
}

String hlsSegmentMagic(Uint8List data) {
  final n = data.length < 8 ? data.length : 8;
  final hex = data
      .sublist(0, n)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(' ');
  if (n >= 2 && data[0] == 0xFF && data[1] == 0xD8) return 'jpeg $hex';
  if (n >= 4 && data[0] == 0x89 && data[1] == 0x50) return 'png $hex';
  if (n >= 4 && data[0] == 0x47) return 'ts $hex';
  if (isoLooksLikeFmp4(data)) return 'fmp4 $hex';
  return hex;
}

double? mpegTsFirstPtsSeconds(Uint8List data) {
  final inspect = mpegTsInspect(data);
  return inspect.videoPts ?? inspect.audioPts;
}

class MpegTsInspect {
  const MpegTsInspect({
    this.pcr,
    this.videoPts,
    this.audioPts,
    this.videoPid,
    this.audioPid,
    this.ptsSamples = const [],
  });
  final double? pcr;
  final double? videoPts;
  final double? audioPts;
  final int? videoPid;
  final int? audioPid;
  final List<double> ptsSamples;

  /// Sidecar VTT origin: audio-behind-video skew, then Apple-style PTS/PCR padding.
  double? get epoch {
    if (audioPts != null && videoPts != null) {
      final skew = audioPts! - videoPts!;
      if (skew >= 0.5 && skew <= 60) return audioPts;
    }
    return _inPaddingRange(videoPts) ??
        _inPaddingRange(audioPts) ??
        _inPaddingRange(pcr);
  }

  String get summary {
    String f(double? v) => v == null ? '-' : v.toStringAsFixed(3);
    final skew = (audioPts != null && videoPts != null)
        ? (audioPts! - videoPts!).toStringAsFixed(3)
        : '-';
    return 'pcr=${f(pcr)}s videoPts=${f(videoPts)}s audioPts=${f(audioPts)}s '
        'avSkew=${skew}s vpid=${videoPid ?? '-'} apid=${audioPid ?? '-'}';
  }
}

/// Apple HLS padding is typically 10s (MPEGTS 900000). Tiny PCR/PTS (~0.1–0.5s)
/// is just the first frame, not a caption origin.
double? _inPaddingRange(double? t) {
  if (t == null || t < 8 || t > 30) return null;
  return t;
}

MpegTsInspect mpegTsInspect(Uint8List data) {
  final bytes = data.length >= 188 * 3 ? hlsStripToTsSync(data) : data;
  final packetSize = _tsPacketSize(bytes);
  if (packetSize == null) return const MpegTsInspect();
  final hdr = packetSize == 192 ? 4 : 0;
  var i = 0;
  double? pcr;
  double? paddingPcr;
  double? videoPts;
  double? audioPts;
  int? pmtPid;
  int? videoPid;
  int? audioPid;
  final audioPids = <int>{};
  final videoPids = <int>{};
  final pmtSeen = <int>{};
  final ptsSamples = <double>[];
  while (i + packetSize <= bytes.length) {
    final sync = i + hdr;
    if (bytes[sync] != 0x47) {
      i += 1;
      continue;
    }
    final pusi = (bytes[sync + 1] & 0x40) != 0;
    final pid = ((bytes[sync + 1] & 0x1f) << 8) | bytes[sync + 2];
    final adapt = (bytes[sync + 3] >> 4) & 0x3;
    var payload = sync + 4;
    if (adapt == 2 || adapt == 3) {
      final adaptLen = bytes[sync + 4];
      if (adaptLen > 0 && payload + 1 + adaptLen <= sync + 188) {
        final flags = bytes[sync + 5];
        if ((flags & 0x10) != 0 && sync + 12 <= bytes.length) {
          final parsed = _mpegTsPcr(bytes, sync + 6);
          pcr ??= parsed;
          paddingPcr ??= _inPaddingRange(parsed);
        }
      }
      payload = sync + 5 + adaptLen;
    }
    i += packetSize;
    if (pid == 0x1fff || !pusi || payload >= sync + 188) continue;
    if (pid == 0) {
      pmtPid ??= _patProgramMapPid(bytes, payload, sync + 188);
      continue;
    }
    if (pmtPid != null && pid == pmtPid && !pmtSeen.contains(pid)) {
      pmtSeen.add(pid);
      final pmt = _pmtAvPids(bytes, payload, sync + 188);
      videoPid ??= pmt.video;
      audioPid ??= pmt.audio;
      if (pmt.video != null) videoPids.add(pmt.video!);
      audioPids.addAll(pmt.audios);
      continue;
    }
    if (payload + 14 > sync + 188) continue;
    if (bytes[payload] != 0 ||
        bytes[payload + 1] != 0 ||
        bytes[payload + 2] != 1) {
      continue;
    }
    if ((bytes[payload + 6] & 0xC0) != 0x80) continue;
    final ptsDts = (bytes[payload + 7] >> 6) & 0x3;
    if (ptsDts < 2) continue;
    if (!_mpegTsPtsMarkersOk(bytes, payload + 9)) continue;
    final pts = _mpegTsPts(bytes, payload + 9) / 90000.0;
    if (ptsSamples.length < 8) ptsSamples.add(pts);
    final streamId = bytes[payload + 3];
    final isVideo = (streamId >= 0xE0 && streamId <= 0xEF) ||
        videoPids.contains(pid);
    final isAudio = (streamId >= 0xC0 && streamId <= 0xDF) ||
        streamId == 0xBD ||
        audioPids.contains(pid);
    if (isVideo) videoPts ??= pts;
    if (isAudio) audioPts ??= pts;
  }
  return MpegTsInspect(
    pcr: paddingPcr ?? pcr,
    videoPts: videoPts,
    audioPts: audioPts,
    videoPid: videoPid,
    audioPid: audioPid,
    ptsSamples: ptsSamples,
  );
}

double? _mpegTsPcr(Uint8List b, int i) {
  if (i + 6 > b.length) return null;
  final base = (b[i] << 25) |
      (b[i + 1] << 17) |
      (b[i + 2] << 9) |
      (b[i + 3] << 1) |
      ((b[i + 4] >> 7) & 1);
  return base / 90000.0;
}

bool _mpegTsPtsMarkersOk(Uint8List b, int i) {
  if (i + 5 > b.length) return false;
  final prefix = b[i] & 0xF1;
  if (prefix != 0x21 && prefix != 0x31) return false;
  return (b[i + 2] & 1) == 1 && (b[i + 4] & 1) == 1;
}

int? _patProgramMapPid(Uint8List b, int payload, int end) {
  var o = payload;
  if (o >= end) return null;
  o += 1 + b[o]; // pointer_field
  if (o + 8 > end || b[o] != 0) return null;
  final sectionLen = ((b[o + 1] & 0x0f) << 8) | b[o + 2];
  final sectionEnd = o + 3 + sectionLen - 4; // minus CRC
  o += 8;
  while (o + 4 <= sectionEnd && o + 4 <= end) {
    final prog = (b[o] << 8) | b[o + 1];
    final pid = ((b[o + 2] & 0x1f) << 8) | b[o + 3];
    o += 4;
    if (prog != 0) return pid;
  }
  return null;
}

class _PmtAvPids {
  const _PmtAvPids({this.video, this.audio, this.audios = const {}});
  final int? video;
  final int? audio;
  final Set<int> audios;
}

_PmtAvPids _pmtAvPids(Uint8List b, int payload, int end) {
  var o = payload;
  if (o >= end) return const _PmtAvPids();
  o += 1 + b[o];
  if (o + 12 > end || b[o] != 0x02) return const _PmtAvPids();
  final sectionLen = ((b[o + 1] & 0x0f) << 8) | b[o + 2];
  final sectionEnd = o + 3 + sectionLen - 4;
  final progInfo = ((b[o + 10] & 0x0f) << 8) | b[o + 11];
  o += 12 + progInfo;
  int? video;
  int? audio;
  final audios = <int>{};
  const videoTypes = {0x01, 0x02, 0x10, 0x1B, 0x24, 0x20, 0x27, 0xDB, 0xEA};
  const audioTypes = {0x03, 0x04, 0x0F, 0x11, 0x81, 0x87, 0x06, 0x83, 0x84};
  while (o + 5 <= sectionEnd && o + 5 <= end) {
    final streamType = b[o];
    final epid = ((b[o + 1] & 0x1f) << 8) | b[o + 2];
    final esInfo = ((b[o + 3] & 0x0f) << 8) | b[o + 4];
    o += 5 + esInfo;
    if (video == null && videoTypes.contains(streamType)) video = epid;
    if (audioTypes.contains(streamType)) {
      audio ??= epid;
      audios.add(epid);
    }
  }
  return _PmtAvPids(video: video, audio: audio, audios: audios);
}

int? _tsPacketSize(Uint8List bytes) {
  if (_hasTsSync(bytes, 188, 0)) return 188;
  if (_hasTsSync(bytes, 192, 4)) return 192;
  if (bytes.length >= 188 && bytes[0] == 0x47) return 188;
  final limit = bytes.length < 4096 ? bytes.length : 4096;
  for (var i = 0; i + 564 < limit; i++) {
    if (bytes[i] == 0x47 &&
        bytes[i + 188] == 0x47 &&
        bytes[i + 376] == 0x47) {
      return 188;
    }
  }
  return null;
}

bool _hasTsSync(Uint8List bytes, int packetSize, int header) {
  if (bytes.length < packetSize * 3) return false;
  return bytes[header] == 0x47 &&
      bytes[header + packetSize] == 0x47 &&
      bytes[header + packetSize * 2] == 0x47;
}

int _mpegTsPts(Uint8List bytes, int i) {
  final b0 = bytes[i];
  final b1 = bytes[i + 1];
  final b2 = bytes[i + 2];
  final b3 = bytes[i + 3];
  final b4 = bytes[i + 4];
  return ((b0 & 0x0E) << 29) |
      (b1 << 22) |
      ((b2 & 0xFE) << 14) |
      (b3 << 7) |
      ((b4 & 0xFE) >> 1);
}

bool isoLooksLikeFmp4(Uint8List data) {
  if (data.length < 8) return false;
  final type = String.fromCharCodes(data.sublist(4, 8));
  return type == 'ftyp' ||
      type == 'styp' ||
      type == 'moof' ||
      type == 'moov' ||
      type == 'sidx';
}

String? hlsExtXMapUri(String playlist) {
  for (final raw in playlist.split('\n')) {
    final line = raw.trim();
    if (!line.toUpperCase().startsWith('#EXT-X-MAP:')) continue;
    return hlsAttr(line, 'URI');
  }
  return null;
}

double? hlsExtXStartOffset(String playlist) {
  final m = RegExp(
    r'#EXT-X-START:[^\n]*TIME-OFFSET=(-?[\d.]+)',
    caseSensitive: false,
  ).firstMatch(playlist);
  if (m == null) return null;
  return double.tryParse(m.group(1)!);
}

class HlsMediaSegment {
  const HlsMediaSegment({
    required this.duration,
    required this.uri,
    required this.discontinuity,
  });
  final double duration;
  final String uri;
  final bool discontinuity;
}

/// Media playlist segments in file order (relative URIs left unresolved).
List<HlsMediaSegment> hlsMediaSegments(String playlist, {int max = 32}) {
  final out = <HlsMediaSegment>[];
  var pendingDuration = 0.0;
  var pendingDisc = false;
  var haveDuration = false;
  for (final raw in playlist.split('\n')) {
    if (out.length >= max) break;
    final line = raw.trim();
    if (line.isEmpty) continue;
    final upper = line.toUpperCase();
    if (upper.startsWith('#EXT-X-DISCONTINUITY') &&
        !upper.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE')) {
      pendingDisc = true;
      continue;
    }
    if (upper.startsWith('#EXTINF:')) {
      final comma = line.indexOf(',');
      final spec = comma < 0 ? line.substring(8) : line.substring(8, comma);
      pendingDuration = double.tryParse(spec.trim()) ?? 0;
      haveDuration = true;
      continue;
    }
    if (line.startsWith('#')) continue;
    if (!haveDuration) continue;
    out.add(
      HlsMediaSegment(
        duration: pendingDuration,
        uri: line,
        discontinuity: pendingDisc,
      ),
    );
    pendingDisc = false;
    haveDuration = false;
    pendingDuration = 0;
  }
  return out;
}

/// Leading content before the first discontinuity, when that looks like a bumper.
double? hlsLeadingDiscontinuitySeconds(List<HlsMediaSegment> segments) {
  if (segments.length < 2) return null;
  final idx = segments.indexWhere((s) => s.discontinuity);
  if (idx <= 0) return null;
  var sum = 0.0;
  for (var i = 0; i < idx; i++) {
    sum += segments[i].duration;
  }
  return _inPaddingRange(sum);
}

double? hlsDateRangeDuration(String playlist) {
  final m = RegExp(
    r'#EXT-X-DATERANGE:[^\n]*DURATION=([\d.]+)',
    caseSensitive: false,
  ).firstMatch(playlist);
  if (m == null) return null;
  return _inPaddingRange(double.tryParse(m.group(1)!));
}

String hlsPlaylistPreview(String playlist, {int maxLines = 24}) {
  final lines = playlist
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .take(maxLines);
  final text = lines.join(' | ');
  return text.length <= 700 ? text : '${text.substring(0, 700)}…';
}

/// `#EXT…` tags only (no segment URIs), for compact timing logs.
String hlsPlaylistTagSummary(String playlist, {int max = 40}) {
  final tags = playlist
      .split('\n')
      .map((l) => l.trim())
      .where(
        (l) =>
            l.startsWith('#') && !l.toUpperCase().startsWith('#EXTINF'),
      )
      .take(max);
  return tags.join(' | ');
}

final _hlsHexId = RegExp(r'^[a-fA-F0-9]{32}$');

/// Last 32-hex path folder (Kryntal-style encode id), or null.
String? hlsCdnEncodeId(String url) {
  final segs = Uri.tryParse(url)?.pathSegments ?? const <String>[];
  String? last;
  for (final s in segs) {
    if (_hlsHexId.hasMatch(s)) last = s;
  }
  return last;
}

/// Rewrite the encode folder in [url] (last 32-hex segment) to [newEncodeId].
String? hlsCdnSwapEncode(String url, String newEncodeId) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final segs = List<String>.from(uri.pathSegments);
  var idx = -1;
  for (var i = 0; i < segs.length; i++) {
    if (_hlsHexId.hasMatch(segs[i])) idx = i;
  }
  if (idx < 0) return null;
  segs[idx] = newEncodeId;
  return uri.replace(pathSegments: segs).toString();
}

double hlsSumExtinf(String playlist) {
  final segs = hlsMediaSegments(playlist, max: 8192);
  return segs.fold<double>(0, (a, s) => a + s.duration);
}

/// Seconds of [playing] that occur before [other]'s EXTINF pattern.
/// 0 means they start together (any duration gap is at the tail).
double? hlsLeadingExtinfSkew(
  List<double> playing,
  List<double> other, {
  double eps = 0.15,
  int needleLen = 12,
}) {
  if (playing.length < 8 || other.length < 8) return null;

  bool matchAt(List<double> hay, int start, List<double> needle) {
    if (start < 0 || start + needle.length > hay.length) return false;
    for (var i = 0; i < needle.length; i++) {
      if ((hay[start + i] - needle[i]).abs() > eps) return false;
    }
    return true;
  }

  double sumBefore(List<double> list, int start) {
    var s = 0.0;
    for (var i = 0; i < start; i++) {
      s += list[i];
    }
    return s;
  }

  double? uniqueLead({required List<double> hay, required List<double> needle}) {
    final n = needle.length;
    if (n < 8 || hay.length < n) return null;
    double? found;
    for (var start = 0; start <= hay.length - n; start++) {
      if (!matchAt(hay, start, needle)) continue;
      final lead = sumBefore(hay, start);
      if (found != null && (found - lead).abs() > eps) return null;
      found = lead;
    }
    return found;
  }

  for (final nTry in [needleLen, 8]) {
    final n = nTry < other.length ? nTry : other.length;
    if (n < 8) continue;
    final lead = uniqueLead(hay: playing, needle: other.take(n).toList());
    if (lead != null) return lead;
    final reverse = uniqueLead(hay: other, needle: playing.take(n).toList());
    if (reverse != null && reverse > 0) return -reverse;
  }
  return null;
}

/// Compact playlist timing dump for `[zangetsu-sub-timing]` logs.
String hlsExtinfFingerprint(List<HlsMediaSegment> segs) {
  if (segs.isEmpty) return 'empty';
  final durs = [for (final s in segs) s.duration];
  final total = durs.fold<double>(0, (a, b) => a + b);
  String fmt(Iterable<double> xs) =>
      xs.map((x) => x.toStringAsFixed(3)).join(',');
  final discs = <String>[];
  var t = 0.0;
  var runLen = 1;
  var runAt = 0.0;
  var bestLen = 1;
  var bestDur = durs.first;
  var bestAt = 0.0;
  for (var i = 0; i < segs.length; i++) {
    if (segs[i].discontinuity) {
      discs.add('${t.toStringAsFixed(1)}s#${i}');
    }
    if (i > 0) {
      if ((durs[i] - durs[i - 1]).abs() <= 0.05) {
        runLen++;
        if (runLen > bestLen) {
          bestLen = runLen;
          bestDur = durs[i];
          bestAt = runAt;
        }
      } else {
        runLen = 1;
        runAt = t;
      }
    }
    t += durs[i];
  }
  final head = fmt(durs.take(16));
  final tail = fmt(durs.skip(durs.length > 16 ? durs.length - 16 : 0));
  final repeat = bestLen >= 4
      ? ' repeat=${bestLen}x${bestDur.toStringAsFixed(3)}@${bestAt.toStringAsFixed(1)}s'
      : '';
  return 'n=${segs.length} dur=${total.toStringAsFixed(3)} '
      'head=[$head] tail=[$tail] '
      'disc=${discs.isEmpty ? "none" : discs.join(",")}'
      '$repeat';
}

/// Highest-resolution variant, preferring [preferBasename] when present.
String? hlsPreferredVariantUri(
  String master,
  String masterUrl, {
  String? preferBasename,
}) {
  final uris = hlsVariantUrisOrdered(
    master,
    masterUrl,
    preferBasename: preferBasename,
  );
  return uris.isEmpty ? null : uris.first;
}

/// Variant URLs from a master: matching basename first, then high→low res.
List<String> hlsVariantUrisOrdered(
  String master,
  String masterUrl, {
  String? preferBasename,
}) {
  final variants = parseHlsMaster(master, masterUrl);
  final out = <String>[];
  if (preferBasename != null && preferBasename.isNotEmpty) {
    for (final v in variants) {
      if (Uri.parse(v.url).pathSegments.last == preferBasename) {
        out.add(v.url);
        break;
      }
    }
  }
  for (final v in variants) {
    if (!out.contains(v.url)) out.add(v.url);
  }
  if (out.isEmpty) {
    final first = hlsFirstUriLine(master);
    if (first != null) out.add(Uri.parse(masterUrl).resolve(first).toString());
  }
  return out;
}

/// Presentation start of an fMP4 init+fragment, in seconds (`tfdt / mdhd`).
double? fmp4BaseMediaTimeSeconds(Uint8List init, [Uint8List? fragment]) {
  var timescale = isoMdhdTimescale(init);
  var tfdt = isoTfdt(init);
  if (fragment != null) {
    timescale ??= isoMdhdTimescale(fragment);
    tfdt ??= isoTfdt(fragment);
  }
  if (timescale == null || timescale <= 0 || tfdt == null) return null;
  return tfdt / timescale;
}

int? isoMdhdTimescale(Uint8List data) {
  int? scale;
  _isoWalk(data, 0, data.length, (type, start, end) {
    if (type != 'mdhd' || scale != null || start + 16 > end) return;
    final version = data[start];
    if (version == 1) {
      if (start + 32 > end) return;
      scale = _isoU32(data, start + 20);
    } else {
      scale = _isoU32(data, start + 12);
    }
  });
  return scale;
}

int? isoTfdt(Uint8List data) {
  int? value;
  _isoWalk(data, 0, data.length, (type, start, end) {
    if (type != 'tfdt' || value != null || start + 8 > end) return;
    final version = data[start];
    if (version == 1) {
      if (start + 12 > end) return;
      value = _isoU64(data, start + 4);
    } else {
      value = _isoU32(data, start + 4);
    }
  });
  return value;
}

void _isoWalk(
  Uint8List data,
  int start,
  int end,
  void Function(String type, int payloadStart, int payloadEnd) visit,
) {
  var i = start;
  while (i + 8 <= end) {
    var size = _isoU32(data, i);
    final type = String.fromCharCodes(data.sublist(i + 4, i + 8));
    var header = 8;
    if (size == 1) {
      if (i + 16 > end) return;
      size = _isoU64(data, i + 8);
      header = 16;
    } else if (size == 0) {
      size = end - i;
    }
    if (size < header || i + size > end) return;
    final payloadStart = i + header;
    final payloadEnd = i + size;
    visit(type, payloadStart, payloadEnd);
    const containers = {
      'moov',
      'trak',
      'mdia',
      'minf',
      'stbl',
      'moof',
      'traf',
      'mvex',
      'edts',
    };
    if (containers.contains(type)) {
      _isoWalk(data, payloadStart, payloadEnd, visit);
    }
    i += size;
  }
}

int _isoU32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

int _isoU64(Uint8List b, int i) {
  final hi = _isoU32(b, i);
  final lo = _isoU32(b, i + 4);
  return (hi << 32) | lo;
}
