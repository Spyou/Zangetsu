import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Dev-only SP0 spike: plays a test stream through the native ExoPlayer
/// SurfaceView (Hybrid Composition) so smoothness can be compared to the
/// media_kit player on the TV. Reachable only behind --dart-define=EXO_SPIKE=1.
class TvExoSpikeScreen extends StatefulWidget {
  const TvExoSpikeScreen({super.key});
  @override
  State<TvExoSpikeScreen> createState() => _TvExoSpikeScreenState();
}

class _TvExoSpikeScreenState extends State<TvExoSpikeScreen> {
  // A public adaptive-bitrate HLS test stream (Mux). Replace via the field to
  // test a real source URL.
  final _urlCtrl = TextEditingController(
    text: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
  );
  MethodChannel? _ch;
  bool _playing = false;

  void _onCreated(int id) {
    _ch = MethodChannel('zangetsu/exoplayer_$id');
    _ch!.invokeMethod<void>('setUrl', {'url': _urlCtrl.text.trim()});
    if (mounted) setState(() => _playing = true);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Hybrid Composition: a REAL SurfaceView in the view hierarchy (the
          // hardware-overlay path). Plain AndroidView would use Virtual Display
          // (a texture) — the exact thing we're trying to avoid.
          Positioned.fill(
            child: PlatformViewLink(
              viewType: 'zangetsu/exoplayer_view',
              surfaceFactory: (context, controller) => AndroidViewSurface(
                controller: controller as AndroidViewController,
                gestureRecognizers:
                    const <Factory<OneSequenceGestureRecognizer>>{},
                hitTestBehavior: PlatformViewHitTestBehavior.transparent,
              ),
              onCreatePlatformView: (params) {
                final controller = PlatformViewsService.initExpensiveAndroidView(
                  id: params.id,
                  viewType: 'zangetsu/exoplayer_view',
                  layoutDirection: TextDirection.ltr,
                  creationParams: const <String, dynamic>{},
                  creationParamsCodec: const StandardMessageCodec(),
                  onFocus: () => params.onFocusChanged(true),
                )
                  ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
                  ..addOnPlatformViewCreatedListener(_onCreated)
                  ..create();
                return controller;
              },
            ),
          ),
          // Minimal Flutter overlay (proves controls draw over the surface).
          Positioned(
            left: 20,
            right: 20,
            bottom: 20,
            child: Row(
              children: [
                FloatingActionButton(
                  heroTag: 'exo-pp',
                  onPressed: () {
                    _ch?.invokeMethod<void>(_playing ? 'pause' : 'play');
                    setState(() => _playing = !_playing);
                  },
                  child: Icon(_playing ? Icons.pause : Icons.play_arrow),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Stream URL',
                      hintStyle: TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Colors.black54,
                    ),
                    onSubmitted: (u) =>
                        _ch?.invokeMethod<void>('setUrl', {'url': u.trim()}),
                  ),
                ),
              ],
            ),
          ),
          const Positioned(
            top: 16,
            left: 16,
            child: Text(
              'ExoPlayer SurfaceView spike (SP0)',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compile-time dev flag: `--dart-define=EXO_SPIKE=1`.
const bool kExoSpikeEnabled = bool.fromEnvironment('EXO_SPIKE');
