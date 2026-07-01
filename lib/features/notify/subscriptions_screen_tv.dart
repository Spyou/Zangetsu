import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/notify/subscription_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/states.dart';
import '../detail/detail_screen.dart';

/// TV Notifications / Subscriptions list — D-pad focusable vertical list of
/// subscribed shows. Reuses the existing subscription row widget (ListTile +
/// cover) and [_openDetail] logic from the phone screen unchanged; only the
/// interaction model shifts from tap to D-pad + OK via [TvFocusable].
///
/// The phone [SubscriptionsScreen] stays byte-identical except for the single
/// `if (sl<AppMode>().isTv) return const SubscriptionsScreenTv();` branch
/// added at the top of [_SubscriptionsScreenState.build].
class SubscriptionsScreenTv extends StatefulWidget {
  const SubscriptionsScreenTv({super.key});

  @override
  State<SubscriptionsScreenTv> createState() => _SubscriptionsScreenTvState();
}

class _SubscriptionsScreenTvState extends State<SubscriptionsScreenTv> {
  SubscriptionStore get _store => sl<SubscriptionStore>();

  Future<void> _openDetail(Subscription s) async {
    await Navigator.of(context).push(
      DetailScreen.route(
        MediaItem(
          id: s.url,
          title: s.title,
          url: s.url,
          type: ProviderType.anime,
          sourceId: s.sourceId,
          cover: s.cover,
          coverHeaders: s.coverHeaders,
        ),
      ),
    );
    if (mounted) setState(() {}); // reflect an unsubscribe done from the detail
  }

  String _sourceLabel(String sourceId) =>
      sourceId.startsWith('cs:') ? sourceId.substring(3) : sourceId;

  @override
  Widget build(BuildContext context) {
    final subs = _store.all();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Title header ──────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
                  child: Text('Notifications', style: AppText.largeTitle),
                ),
                // ── Subscription list ─────────────────────────────────────────
                Expanded(
              child: subs.isEmpty
                  ? const EmptyState(
                      icon: Icons.notifications_none_rounded,
                      message:
                          'No notifications yet.\nTap the bell on a show to get alerted '
                          'when a new episode is out.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: subs.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, color: AppColors.hairline),
                      itemBuilder: (context, i) {
                        final s = subs[i];
                        // Reuse the existing row widget verbatim, wrapped in
                        // TvFocusable so D-pad up/down navigates and OK opens
                        // the same Detail screen as the phone tap.
                        return TvFocusable(
                          autofocus: i == 0,
                          onTap: () => _openDetail(s),
                          child: ListTile(
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 44,
                                height: 62,
                                child: (s.cover != null && s.cover!.isNotEmpty)
                                    ? CachedNetworkImage(
                                        imageUrl: s.cover!,
                                        httpHeaders: s.coverHeaders,
                                        fit: BoxFit.cover,
                                        errorWidget: (_, _, _) => const ColoredBox(
                                          color: AppColors.surface2,
                                        ),
                                      )
                                    : const ColoredBox(color: AppColors.surface2),
                              ),
                            ),
                            title: Text(
                              s.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.body
                                  .copyWith(color: AppColors.textPrimary),
                            ),
                            subtitle: Text(
                              _sourceLabel(s.sourceId),
                              style: AppText.caption,
                            ),
                          ),
                        );
                      },
                    ),
                ),
              ],
            ),
          ), // SafeArea
          const Positioned(top: 8, left: 8, child: SafeArea(child: TvBackButton())),
        ], // Stack children
      ), // Stack (body)
    );
  }
}
