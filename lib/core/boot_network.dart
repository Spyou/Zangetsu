import 'dart:async';
import 'dart:io';

/// One-shot boot connectivity probe. Cold start awaits cloud work serially
/// (Supabase init, profile merge, library sync, lock-status RPC), and on a
/// blackholed network — Wi-Fi with no internet, the common "offline" case —
/// each stage burns its full multi-second timeout instead of failing fast.
/// A single fast probe lets boot skip the cloud half entirely; everything it
/// skips self-heals when the network returns (retry init, resume sync, lock
/// cache fallback). Any failure means offline — skipping cloud work when the
/// network is merely strange only delays a sync that retries anyway.
Future<bool> probeBootOffline({
  required String host,
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (host.isEmpty) return false;
  try {
    final socket = await Socket.connect(host, 443, timeout: timeout);
    socket.destroy();
    return false;
  } catch (_) {
    return true;
  }
}
