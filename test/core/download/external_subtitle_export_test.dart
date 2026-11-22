import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/external_subtitle_export.dart';

void main() {
  test('exports subtitles into the same custom destination as the video', () {
    expect(
      externalSubtitleDestination(
        videoPath:
            'content://com.android.externalstorage.documents/tree/primary%3AAniAura/document/primary%3AAniAura%2FE1.mp4',
        privateStorageRoot: '/data/user/0/app/files',
        locationUri:
            'content://com.android.externalstorage.documents/tree/primary%3AAniAura',
      ),
      ExternalSubtitleDestination.safTree,
    );
    expect(
      externalSubtitleDestination(
        videoPath:
            '/storage/ABCD-1234/Android/data/app/files/Downloads/AniAura/Show/E1.mp4',
        privateStorageRoot: '/data/user/0/app/files',
        locationUri: '/storage/ABCD-1234/Android/data/app/files/Downloads',
      ),
      ExternalSubtitleDestination.besideVideo,
    );
  });

  test('recovers the SAF tree from the saved video URI', () {
    expect(
      externalSubtitleTreeUri(
        'content://com.android.externalstorage.documents/tree/primary%3AAniAura/document/primary%3AAniAura%2FE1.mp4',
      ),
      'content://com.android.externalstorage.documents/tree/primary%3AAniAura',
    );
  });

  test('keeps private sidecars private and default sidecars in Downloads', () {
    expect(
      externalSubtitleDestination(
        videoPath: '/data/user/0/app/files/AniAura/Show/E1.mp4',
        privateStorageRoot: '/data/user/0/app/files',
        locationUri: null,
      ),
      ExternalSubtitleDestination.privateStorage,
    );
    expect(
      externalSubtitleDestination(
        videoPath: '/storage/emulated/0/Download/AniAura/Show/E1.mp4',
        privateStorageRoot: '/data/user/0/app/files',
        locationUri: null,
      ),
      ExternalSubtitleDestination.sharedDownloads,
    );
  });

  test('videos inside app storage never export public subtitle sidecars', () {
    expect(
      shouldExportSubtitleSidecars(
        videoPath: '/data/user/0/app/files/AniAura/Show/episode.mp4',
        privateStorageRoot: '/data/user/0/app/files',
      ),
      isFalse,
    );
    expect(
      shouldExportSubtitleSidecars(
        videoPath: '/storage/emulated/0/Download/AniAura/Show/episode.mp4',
        privateStorageRoot: '/data/user/0/app/files',
      ),
      isTrue,
    );
    expect(
      shouldExportSubtitleSidecars(
        videoPath: '/data/user/0/app/files-backup/episode.mp4',
        privateStorageRoot: '/data/user/0/app/files',
      ),
      isTrue,
    );
  });

  test('names the public sidecar after the video and its language', () {
    expect(
      externalSubtitleFileName(
        videoPath: '/storage/Download/AniAura/Show/episode_1080p.mp4',
        language: 'en',
        extension: '.srt',
      ),
      'episode_1080p.en.srt',
    );
  });

  test('sanitizes subtitle language labels for public filenames', () {
    expect(
      externalSubtitleFileName(
        videoPath: '/storage/Download/AniAura/Show/episode.mp4',
        language: 'pt-BR/commentary',
        extension: '.vtt',
      ),
      'episode.pt-BR_commentary.vtt',
    );
  });

  test('converts WebVTT timestamps to SRT and keeps multiline cue text', () {
    expect(
      webVttToSrt('''
WEBVTT

00:00:01.250 --> 00:00:03.500 align:start position:10%
First line
Second line
'''),
      '1\n00:00:01,250 --> 00:00:03,500\nFirst line\nSecond line\n',
    );
  });

  test('adds an hour field to WebVTT short timestamps', () {
    expect(
      webVttToSrt('WEBVTT\n\n01:02.5 --> 01:04.000\nHello\n'),
      '1\n00:01:02,500 --> 00:01:04,000\nHello\n',
    );
  });

  test('publishes WebVTT as SRT while preserving other subtitle formats', () {
    expect(publicSubtitleExtension('/private/subs/en.vtt'), '.srt');
    expect(publicSubtitleExtension('/private/subs/en.ass'), '.ass');
    expect(publicSubtitleExtension('/private/subs/en.srt'), '.srt');
  });
}
