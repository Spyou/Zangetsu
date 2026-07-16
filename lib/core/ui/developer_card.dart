import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// The "Developer" credits card — GitHub avatar + name/role and tappable
/// social links. Styled for Zangetsu's dark/coral theme.
class DeveloperCard extends StatelessWidget {
  const DeveloperCard({
    super.key,
    this.name = 'Krishna Vishwakarma',
    this.role = 'Lead developer',
    this.description = 'Web & app developer · UI/UX designer',
    this.github = 'spyou',
    this.telegram = 'kbot09',
  });

  final String name;
  final String role;
  final String description;
  final String github;
  final String? telegram;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
            child: Row(
              children: [
                _GithubAvatar(username: github, initials: _initials, size: 58),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: AppText.headline),
                      const SizedBox(height: 3),
                      Text(
                        role,
                        style: AppText.caption.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        description,
                        style: AppText.caption.copyWith(
                          color: AppColors.textTertiary,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1, color: AppColors.hairline),
          _LinkRow(
            label: 'GitHub',
            handle: '@$github',
            url: 'https://github.com/$github',
          ),
          if (telegram != null) ...[
            const Divider(
              height: 1,
              thickness: 1,
              indent: 16,
              endIndent: 16,
              color: AppColors.hairline,
            ),
            _LinkRow(
              label: 'Telegram',
              handle: '@$telegram',
              url: 'https://t.me/$telegram',
            ),
          ],
        ],
      ),
    );
  }
}

class _GithubAvatar extends StatelessWidget {
  const _GithubAvatar({
    required this.username,
    required this.initials,
    required this.size,
  });

  final String username;
  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.accentSoft,
      ),
      child: Text(
        initials,
        style: TextStyle(
          fontFamily: 'Inter',
          color: AppColors.accent,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.36,
        ),
      ),
    );
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: 'https://github.com/$username.png?size=200',
        width: size,
        height: size,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 180),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.label,
    required this.handle,
    required this.url,
  });

  final String label;
  final String handle;
  final String url;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final uri = Uri.parse(url);
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          await launchUrl(uri, mode: LaunchMode.platformDefault);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Text(
              label,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                handle,
                textAlign: TextAlign.end,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.arrow_outward_rounded,
              size: 16,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
