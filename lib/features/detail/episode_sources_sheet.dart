import 'dart:async';

import 'package:flutter/material.dart';
import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/zmode/playback_resolver.dart';

/// "Where can I watch this one?" — the sources that HAVE the episode, listed
/// as they answer.
///
/// Only hits are listed. An earlier version drew the whole queue with a
/// pending/checking/no state per row, which read well with a dozen sources and
/// fell apart with a hundred: a wall of rows saying "no", most of the list
/// irrelevant, and the scroll fighting the scrapes for the same isolate. What
/// someone actually wants here is the short answer — who has it — with the
/// progress kept to one line.
///
/// The sweep stops early by design (see [PlaybackResolver.probeEach]); "Keep
/// checking" resumes past that for the rare case the first few had nothing.
///
/// A centred dialog rather than a bottom sheet: this is a question being
/// answered, not a drawer of options, and the answer is usually three or four
/// lines. A sheet the size of a postage stamp anchored to the bottom edge read
/// as an afterthought.
///
/// Returns the chosen source, or null if they backed out.
Future<SourceProbe?> showEpisodeSourcesSheet(
  BuildContext context, {
  required Episode episode,
}) => showDialog<SourceProbe>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: AppColors.surface,
    insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    child: _EpisodeSourcesBody(episode: episode),
  ),
);

class _EpisodeSourcesBody extends StatefulWidget {
  const _EpisodeSourcesBody({required this.episode});
  final Episode episode;

  @override
  State<_EpisodeSourcesBody> createState() => _EpisodeSourcesBodyState();
}

class _EpisodeSourcesBodyState extends State<_EpisodeSourcesBody> {
  final _found = <SourceProbe>[];

  /// Everything asked so far, so "Keep checking" resumes rather than restarts.
  final _asked = <String>{};
  StreamSubscription<SourceProbe>? _sub;
  String? _checking;
  bool _done = false;
  late final int _total;

  /// id → (ecosystem-prefixed label, repo) — the same two pieces the source
  /// picker shows, for the same reason.
  ///
  /// The bare display name is not enough to tell sources apart: "AniKoto" (a
  /// Zangetsu provider) and "Anikage" (a CloudStream plugin) read as the same
  /// thing in a list, and several repos ship a source of the same name. The
  /// prefix says WHICH KIND of provider it is, the small line says which repo
  /// it came from.
  ///
  /// Built once: [categorizedSources] walks every installed manager, which is
  /// not something to do per row.
  final _tags = <String, ({String label, String? repo})>{};

  // ── Frame-stall measurement ─────────────────────────────────────────────
  //
  // A frame that never happens does not report itself, so the signal is the
  // GAP between the frames that did: a scrape blocking this isolate for two
  // seconds shows up as a two-second hole. Logged once per pass so a device
  // log can say how bad it actually was rather than how bad it felt.
  Duration? _lastFrame;
  var _worstGapMs = 0;
  var _stalls = 0;
  void Function(List<FrameTiming>)? _timings;

  void _watchFrames() {
    _timings = (list) {
      for (final t in list) {
        final now = Duration(
          microseconds: t.timestampInMicroseconds(FramePhase.rasterFinish),
        );
        final last = _lastFrame;
        if (last != null) {
          final gapMs = (now - last).inMilliseconds;
          if (gapMs > _worstGapMs) _worstGapMs = gapMs;
          // Past ~4 dropped frames at 60Hz is a stall a person sees.
          if (gapMs > 64) _stalls++;
        }
        _lastFrame = now;
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_timings!);
  }

  void _reportFrames(String when) {
    debugPrint(
      '[probe-ui] $when · worst frame gap ${_worstGapMs}ms · '
      '$_stalls stalls over 64ms',
    );
  }

  @override
  void initState() {
    super.initState();
    _watchFrames();
    _total = sl<PlaybackResolver>()
        .candidatesForEpisode(widget.episode.url)
        .length;
    // Best-effort: a missing repo tag must never stop the list from working.
    try {
      final b = categorizedSources();
      for (final r in [...b.anime, ...b.movies, ...b.nsfw]) {
        _tags[r.id] = (
          label: r.label,
          repo: (r.repo?.isNotEmpty ?? false) ? r.repo : null,
        );
      }
    } catch (_) {/* tags are cosmetic */}
    _start();
  }

  void _start() {
    setState(() => _done = false);
    _sub?.cancel();
    _sub = sl<PlaybackResolver>()
        .probeEach(widget.episode.url, skip: _asked)
        .listen(
          (p) {
            if (!mounted) return;
            setState(() {
              if (p.checking) {
                _checking = p.name;
                return;
              }
              _asked.add(p.sourceId);
              _checking = null;
              if (p.hasEpisode) _found.add(p);
            });
          },
          onDone: () {
            _reportFrames('pass done');
            if (mounted) setState(() => _done = true);
          },
          onError: (_) {
            _reportFrames('pass errored');
            if (mounted) setState(() => _done = true);
          },
        );
  }

  /// Stops asking, keeps what was found. The sweep is real work on a shared
  /// isolate — someone who has seen enough should be able to call it off
  /// without closing the answer they came for.
  void _stop() {
    _sub?.cancel();
    _sub = null;
    if (mounted) {
      setState(() {
        _checking = null;
        _done = true;
      });
    }
  }

  @override
  void dispose() {
    // Stops the sweep the moment the sheet closes — carrying on scraping for
    // an episode nobody is waiting on would be pure cost, and on this isolate
    // it would keep stealing frames from whatever is on screen next.
    _sub?.cancel();
    _reportFrames('closed');
    if (_timings != null) {
      SchedulerBinding.instance.removeTimingsCallback(_timings!);
    }
    super.dispose();
  }

  String get _status {
    // Nothing installed at all: there is no survey to report on, and "none of
    // the 0 checked" would be a nonsense sentence in front of a new user.
    if (_total == 0) return 'No sources installed yet';
    if (!_done) {
      return _checking == null
          ? 'Checking your sources…'
          : 'Checking $_checking…';
    }
    final n = _found.length;
    if (n == 0) return 'None of the ${_asked.length} checked lists it';
    final left = _total - _asked.length;
    return '$n ${n == 1 ? "source has" : "sources have"} it'
        '${left > 0 ? " · $left not asked" : ""}';
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.episode.number?.toInt();
    final more = _done && _asked.length < _total;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.62,
      ),
      child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      n == null
                          ? 'Where to watch'
                          : 'Where to watch episode $n',
                      style: AppText.title.copyWith(fontSize: 17),
                    ),
                  ),
                  // A dialog with a running job in it needs a way out that
                  // isn't guessing whether tapping outside will work.
                  _tvAware(
                    onTap: () => Navigator.pop(context),
                    semanticLabel: 'Close',
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _status,
                style: AppText.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              if (!_done)
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    backgroundColor: AppColors.hairline,
                    color: AppColors.accent,
                  ),
                ),
              if (_total == 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Install a source from the Sources tab and this will show '
                    'which of them has each episode.',
                    style: AppText.caption.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
              if (_found.isNotEmpty) ...[
                const SizedBox(height: 6),
                Flexible(
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: _found.length,
                    itemBuilder: (context, i) => _FoundRow(
                      probe: _found[i],
                      tag: _tags[_found[i].sourceId],
                      onTap: () => Navigator.pop(context, _found[i]),
                    ),
                  ),
                ),
              ],
              if (!_done) ...[
                const SizedBox(height: 12),
                _WideButton(
                  label: 'Stop',
                  onTap: _stop,
                ),
              ] else if (more) ...[
                const SizedBox(height: 12),
                _WideButton(
                  label: 'Check the remaining ${_total - _asked.length}',
                  onTap: _start,
                ),
              ],
            ],
          ),
        ),
    );
  }
}

class _FoundRow extends StatelessWidget {
  const _FoundRow({
    required this.probe,
    required this.onTap,
    this.tag,
  });
  final SourceProbe probe;

  /// The picker's own label (ecosystem-prefixed) and repo, when the registries
  /// could be read. Falls back to the plain source name.
  final ({String label, String? repo})? tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _tvAware(
    onTap: onTap,
    semanticLabel: probe.name,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      child: Row(
        children: [
          Icon(Icons.play_arrow_rounded, size: 20, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tag?.label ?? probe.name,
                  style: AppText.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (tag?.repo != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    tag!.repo!,
                    style: AppText.caption.copyWith(
                      color: AppColors.textTertiary,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: AppColors.textTertiary,
          ),
        ],
      ),
    ),
  );
}


/// D-pad focus with the app's own highlight on TV, a plain InkWell on a
/// phone. A bare InkWell is reachable by remote but draws nothing, so on TV
/// you cannot see which row you are on.
Widget _tvAware({
  required VoidCallback onTap,
  required String semanticLabel,
  required Widget child,
}) {
  final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
  if (!isTv) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: child,
    );
  }
  return TvFocusable(
    variant: TvFocusVariant.box,
    scale: 1.0,
    semanticLabel: semanticLabel,
    onTap: onTap,
    child: child,
  );
}

class _WideButton extends StatelessWidget {
  const _WideButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Material(
      color: AppColors.accentSoft,
      borderRadius: BorderRadius.circular(30),
      clipBehavior: Clip.antiAlias,
      child: _tvAware(
        onTap: onTap,
        semanticLabel: label,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(
              color: AppColors.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );
}
