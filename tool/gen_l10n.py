#!/usr/bin/env python3
"""Generate app_*.arb from the explicit catalog + UI-string scrape."""
from __future__ import annotations

import json
import re
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "lib/l10n"

RESERVED = {
    "assert", "break", "case", "catch", "class", "const", "continue", "default",
    "do", "else", "enum", "extends", "false", "final", "finally", "for", "if",
    "in", "is", "new", "null", "rethrow", "return", "super", "switch", "this",
    "throw", "true", "try", "var", "void", "while", "with", "typedef", "late",
    "required", "await", "yield", "async", "sync", "hide", "show", "library",
    "import", "export", "part", "external", "factory", "operator", "static",
    "abstract", "covariant", "deferred", "get", "set", "implements", "mixin",
    "interface", "base", "sealed", "when",
}

BRANDS = {
    "Zangetsu", "AniList", "MyAnimeList", "Simkl", "MAL", "Discord", "GitHub",
    "Telegram", "CloudStream", "Aniyomi", "Mihon", "LNReader", "PayPal", "DRM",
    "AL", "SK", "SOURCE", "HOST", "CODE", "LIVE", "ACTIVE", "ANIYOMI", "MIHON",
    "UPI · India", "Krishna Vishwakarma", "zangetsu.online",
}

# Explicit keys (name -> english). Placeholders use {name} / ICU plural.
EXPLICIT: list[tuple[str, str, dict]] = [
    # ── common ────────────────────────────────────────────────────────────
    ("cancel", "Cancel", {}),
    ("ok", "OK", {}),
    ("save", "Save", {}),
    ("close", "Close", {}),
    ("retry", "Retry", {}),
    ("search", "Search", {}),
    ("off", "Off", {}),
    ("on", "On", {}),
    ("done", "Done", {}),
    ("next", "Next", {}),
    ("back", "Back", {}),
    ("edit", "Edit", {}),
    ("delete", "Delete", {}),
    ("share", "Share", {}),
    ("copy", "Copy", {}),
    ("play", "Play", {}),
    ("pause", "Pause", {}),
    ("yes", "Yes", {}),
    ("no", "No", {}),
    ("all", "All", {}),
    ("none", "None", {}),
    ("auto", "Auto", {}),
    ("add", "Add", {}),
    ("remove", "Remove", {}),
    ("install", "Install", {}),
    ("uninstall", "Uninstall", {}),
    ("reset", "Reset", {}),
    ("clear", "Clear", {}),
    ("resume", "Resume", {}),
    ("download", "Download", {}),
    ("update", "Update", {}),
    ("apply", "Apply", {}),
    ("enable", "Enable", {}),
    ("create", "Create", {}),
    ("rename", "Rename", {}),
    ("move", "Move", {}),
    ("join", "Join", {}),
    ("leave", "Leave", {}),
    ("skip", "Skip", {}),
    ("later", "Later", {}),
    ("dismiss", "Dismiss", {}),
    ("refresh", "Refresh", {}),
    ("more", "More", {}),
    ("info", "Info", {}),
    ("filter", "Filter", {}),
    ("connect", "Connect", {}),
    ("disconnect", "Disconnect", {}),
    ("signIn", "Sign in", {}),
    ("logOut", "Log out", {}),
    ("tryAgain", "Try again", {}),
    ("showDetails", "Show details", {}),
    ("hideDetails", "Hide details", {}),
    ("notNow", "Not now", {}),
    ("change", "Change", {}),
    ("go", "Go", {}),
    ("read", "Read", {}),
    ("web", "Web", {}),
    ("live", "Live", {}),
    ("sub", "Sub", {}),
    ("dub", "Dub", {}),
    ("nsfw", "NSFW", {}),
    ("system", "System", {}),
    ("custom", "Custom", {}),
    ("defaultLabel", "Default", {}),
    ("selected", "selected", {}),
    ("loading", "Loading…", {}),
    ("searching", "Searching", {}),
    ("searchingEllipsis", "searching…", {}),
    ("downloading", "Downloading…", {}),
    ("updating", "Updating…", {}),
    ("testing", "Testing…", {}),
    ("working", "Working", {}),
    ("dead", "Dead", {}),
    ("error", "Error", {}),
    # ── language picker ───────────────────────────────────────────────────
    ("appLanguage", "App language", {}),
    ("appLanguageSubtitle", "Interface language", {}),
    ("appLanguageSystem", "System (auto)", {}),
    ("appLanguageSystemSubtitle", "System ({name})", {"name": {"type": "String"}}),
    ("appLanguageKeywords", "language locale translation i18n interface japanese chinese spanish german french italian", {}),
    # ── settings hub ──────────────────────────────────────────────────────
    ("settingsTitle", "Settings", {}),
    ("settingsSearchHint", "Search settings", {}),
    ("settingsNoMatch", "No settings match \"{query}\"", {"query": {"type": "String"}}),
    ("settingsSectionAccount", "Account & sync", {}),
    ("settingsSectionSources", "Sources", {}),
    ("settingsSectionPlayback", "Playback", {}),
    ("settingsSectionReading", "Reading", {}),
    ("settingsSectionHistory", "History", {}),
    ("settingsSectionDownloads", "Downloads", {}),
    ("settingsSectionInterface", "Interface", {}),
    ("settingsSectionNotifications", "Notifications", {}),
    ("settingsSectionAdvanced", "Advanced", {}),
    ("settingsSectionAbout", "About", {}),
    ("settingsSectionAccountSummary", "Trackers, Discord, backup, sync", {}),
    ("settingsSectionSourcesSummary", "Providers, active source, updates", {}),
    ("settingsSectionPlaybackSummary", "Quality, autoplay, speed", {}),
    ("settingsSectionReadingSummary", "Manga & novel reader defaults", {}),
    ("settingsSectionHistorySummary", "Shows you've watched", {}),
    ("settingsSectionDownloadsSummary", "Downloads, storage, torrents", {}),
    ("settingsSectionInterfaceSummary", "Appearance, language, search layout", {}),
    ("settingsSectionNotificationsSummary", "New-episode alerts", {}),
    ("settingsSectionAdvancedSummary", "DNS, privacy, logs", {}),
    ("settingsSectionAboutSummary", "Updates, support, version", {}),
    ("couldNotExportLogs", "Could not export logs", {}),
    ("logsShareSubject", "Zangetsu logs", {}),
    ("signInSubtitle", "Sync your list, history & continue watching", {}),
    ("signInSubtitleTv", "Sync your list & continue watching", {}),
    ("connections", "Connections", {}),
    ("discord", "Discord", {}),
    ("discordSubtitle", "Rich Presence — show your status", {}),
    ("watchParty", "Watch Party", {}),
    ("watchPartySubtitle", "Create or join a watch party with friends", {}),
    ("signInToWatchTogether", "Sign in to watch together", {}),
    ("syncLibraryToCloud", "Sync library to cloud", {}),
    ("syncLibraryToCloudSubtitle", "Re-upload history & list to this account", {}),
    ("signInFirst", "Sign in first", {}),
    ("reconnectToSyncLibrary", "Reconnect to sync your library.", {}),
    ("syncingLibraryToCloud", "Syncing your library to cloud…", {}),
    ("backupAndRestore", "Backup & Restore", {}),
    ("backupAndRestoreSubtitle", "Save your sources, list & settings", {}),
    ("providers", "Providers", {}),
    ("providersEnabledCount", "{count} enabled", {"count": {"type": "int"}}),
    ("activeSource", "Active source", {}),
    ("sourceHealth", "Source health", {}),
    ("sourceHealthSubtitle", "Test which sources are working", {}),
    ("sourceUpdates", "Source updates", {}),
    ("sourceUpdatesSubtitle", "Notify when installed sources have updates", {}),
    ("autoUpdateExtensions", "Auto-update extensions", {}),
    ("autoUpdateExtensionsSubtitle", "Update installed sources automatically on launch", {}),
    ("playback", "Playback", {}),
    ("playbackSubtitle", "Quality, autoplay, speed", {}),
    ("reader", "Reader", {}),
    ("readerSubtitle", "Manga & novel reading defaults", {}),
    ("history", "History", {}),
    ("historySubtitle", "Shows you've watched", {}),
    ("downloads", "Downloads", {}),
    ("downloadsSubtitle", "Manage your downloaded episodes", {}),
    ("downloadsSubtitleTv", "Watch offline", {}),
    ("storage", "Storage", {}),
    ("storageSubtitle", "Manage space used by the app", {}),
    ("torrents", "Torrents", {}),
    ("torrentsSubtitle", "Streaming & data settings", {}),
    ("appearance", "Appearance", {}),
    ("appearanceSubtitle", "Accent colour, poster badges", {}),
    ("searchLayout", "Search layout", {}),
    ("searchLayoutSubtitle", "How cross-source results are shown", {}),
    ("searchLayoutBlurb", "How cross-source results are shown. Vertical = a grid per source; Horizontal = a scrolling row per source.", {}),
    ("searchLayoutVertical", "Vertical (grid)", {}),
    ("searchLayoutHorizontal", "Horizontal (rows)", {}),
    ("batchDownloadStyle", "Batch download style", {}),
    ("batchDownloadStyleSubtitle", "How the multi-episode sheet looks", {}),
    ("batchDownloadStyleBlurb", "The sheet shown when you download a whole season. Both download exactly the same — only the picker looks different.", {}),
    ("batchDownloadClassic", "Classic", {}),
    ("batchDownloadClassicBlurb", "The full sheet with a per-episode thumbnail grid.", {}),
    ("batchDownloadMinimal", "Minimal", {}),
    ("batchDownloadMinimalBlurb", "A number wheel — pick how many episodes to grab.", {}),
    ("notifications", "Notifications", {}),
    ("notificationsSubtitle", "New-episode alerts for subscribed shows", {}),
    ("dns", "DNS", {}),
    ("dnsSubtitle", "Bypass ISP blocks on CS sources", {}),
    ("dnsBlurb", "Encrypted DNS for CloudStream sources — helps bypass ISP blocking. Off = your normal connection.", {}),
    ("dnsOffTvSubtitle", "Off · bypass ISP blocks on CS sources", {}),
    ("privacy", "Privacy", {}),
    ("privacySubtitle", "NSFW sources", {}),
    ("shareLogs", "Share logs", {}),
    ("shareLogsSubtitle", "Send a diagnostic log to help fix an issue", {}),
    ("about", "About", {}),
    ("versionLabel", "v{version}", {"version": {"type": "String"}}),
    ("contributors", "Contributors", {}),
    ("website", "Website", {}),
    ("communityChat", "Community chat", {}),
    ("joinTheServer", "Join the server", {}),
    ("viewTheSourceCode", "View the source code", {}),
    ("howItWorks", "How it works", {}),
    ("howItWorksSubtitle", "New here? A quick guide", {}),
    ("checkForUpdates", "Check for updates", {}),
    ("checkForUpdatesSubtitle", "Get the latest version from GitHub", {}),
    ("checkingForUpdates", "Checking for updates…", {}),
    ("betaUpdates", "Beta updates", {}),
    ("betaUpdatesSubtitle", "Get pre-release builds early — may be unstable", {}),
    ("supportTheApp", "Support the app", {}),
    ("buyMeACoffee", "Buy me a coffee", {}),
    ("leadDeveloper", "Lead Developer", {}),
    ("addCloudStreamRepository", "Add CloudStream repository", {}),
    ("installCloudStreamSources", "Install CloudStream sources", {}),
    ("connectionsTvSubtitle", "AniList, MyAnimeList, Simkl", {}),
    ("profile", "Profile", {}),
    # ── shell ─────────────────────────────────────────────────────────────
    ("home", "Home", {}),
    ("myList", "My List", {}),
    ("schedule", "Schedule", {}),
    ("pressBackAgainToExit", "Press BACK again to exit", {}),
    ("pressBackAgainToExitTv", "Press back again to exit", {}),
    ("selectSource", "Select Source", {}),
    # ── accents / shaders / player info ───────────────────────────────────
    ("accentWallpaper", "Wallpaper", {}),
    ("accentCoral", "Coral", {}),
    ("accentBlue", "Blue", {}),
    ("accentViolet", "Violet", {}),
    ("accentEmerald", "Emerald", {}),
    ("accentAmber", "Amber", {}),
    ("accentRose", "Rose", {}),
    ("accentCyan", "Cyan", {}),
    ("accentCrimson", "Crimson", {}),
    ("shaderOff", "Off", {}),
    ("shaderOffDesc", "No enhancement", {}),
    ("shaderSharpen", "Sharpen", {}),
    ("shaderSharpenDesc", "Restore detail — best for clean sources", {}),
    ("shaderDeblur", "De-blur", {}),
    ("shaderDeblurDesc", "Softer restore — for blurry / soft sources", {}),
    ("shaderDenoise", "Denoise", {}),
    ("shaderDenoiseDesc", "Clean up grain — for compressed sources", {}),
    ("shaderTierHigh", "High-end GPU", {}),
    ("shaderTierHighDesc", "Heavier VL upscalers + HQ scaling — needs a strong GPU", {}),
    ("shaderTierMid", "Mid-range GPU", {}),
    ("shaderTierMidDesc", "Light upscalers + deband — smooth on most phones", {}),
    ("playerInfoResolution", "Resolution", {}),
    ("playerInfoSource", "Source", {}),
    ("playerInfoQuality", "Quality", {}),
    ("playerInfoVideoCodec", "Video codec", {}),
    ("playerInfoAudioCodec", "Audio codec", {}),
    ("playerInfoFrameRate", "Frame rate", {}),
    ("playerInfoVideoBitrate", "Video bitrate", {}),
    ("playerInfoBuffer", "Buffer", {}),
    ("playerInfoDroppedFrames", "Dropped frames", {}),
    ("playerInfoDecoder", "Decoder", {}),
    ("playerInfoSpeed", "Speed", {}),
    ("playerInfoAudioTrack", "Audio track", {}),
    ("playerInfoSubtitleTrack", "Subtitle track", {}),
    ("playerInfoAudioBoost", "Audio boost", {}),
    # ── watch status / content mode ───────────────────────────────────────
    ("statusPlanToWatch", "Plan to Watch", {}),
    ("statusWatching", "Watching", {}),
    ("statusCompleted", "Completed", {}),
    ("statusPaused", "Paused", {}),
    ("statusDropped", "Dropped", {}),
    ("statusPlanning", "Planning", {}),
    ("statusReading", "Reading", {}),
    ("statusPlanToRead", "Plan to Read", {}),
    ("modeStreaming", "Streaming", {}),
    ("modeManga", "Manga", {}),
    ("modeNovel", "Novel", {}),
    # ── relative dates ────────────────────────────────────────────────────
    ("relativeToday", "Today", {}),
    ("relativeYesterday", "Yesterday", {}),
    ("relativeDaysAgo", "{count, plural, one {{count} day ago} other {{count} days ago}}", {"count": {"type": "int"}}),
    ("relativeWeeksAgo", "{count, plural, one {{count} week ago} other {{count} weeks ago}}", {"count": {"type": "int"}}),
    ("relativeMonthsAgo", "{count, plural, one {{count} month ago} other {{count} months ago}}", {"count": {"type": "int"}}),
    ("relativeYearsAgo", "{count, plural, one {{count} year ago} other {{count} years ago}}", {"count": {"type": "int"}}),
    # ── boot / onboarding ─────────────────────────────────────────────────
    ("bootErrorTitle", "Zangetsu didn't finish starting", {}),
    ("bootErrorBody", "Something saved on this device is stopping it from opening. Nothing is lost — your account and anything synced to the cloud are safe.", {}),
    ("resetAppData", "Reset app data", {}),
    ("resetAppDataTitle", "Reset app data?", {}),
    ("resetAppDataBody", "This clears what Zangetsu has saved on this device so it can start fresh.\n\nYour account and anything synced to the cloud are not touched — sign in again and your library comes back.", {}),
    ("resetAppDataDone", "Close Zangetsu completely and open it again.", {}),
    ("detailsCopied", "Details copied — send them to us", {}),
    ("copyDetails", "Copy details", {}),
    ("goodToHaveYouHere", "Good to have you here.", {}),
    ("onboardingIntro", "Anime, manga and novels — all in one app, set up your way.", {}),
    ("youChooseWhatsInside", "You choose what's inside", {}),
    ("addTheSourcesYouWant", "Add the sources you want — here's how.", {}),
    ("openProviders", "Open Providers", {}),
    ("pickStreamingMangaOrNovels", "Pick streaming, manga or novels", {}),
    ("pasteInARepositoryLink", "Paste in a repository link", {}),
    ("browseAndGrab", "Browse it and grab what looks good", {}),
    ("readyWhenYouAre", "Ready when you are.", {}),
    ("addSourcesNow", "Add sources now", {}),
    ("illDoItLater", "I'll do it later", {}),
    ("howToUseTheApp", "How to use the app", {}),
    ("aFewTapsToAnything", "A few taps to anything.", {}),
    ("findSomething", "Find something", {}),
    ("watchIt", "Watch it", {}),
    ("ifItWontLoad", "If it won't load", {}),
    ("saveForOffline", "Save for offline", {}),
    ("commonQuestions", "Common questions", {}),
]
# (key, en, placeholders) — placeholders empty dict means none


def to_key(text: str) -> str:
    words = re.findall(r"[A-Za-z0-9]+", text)
    if not words:
        return "s"
    key = words[0].lower() + "".join(w[:1].upper() + w[1:] for w in words[1:])
    if key[0].isdigit():
        key = "n" + key
    if key in RESERVED:
        key = key + "Label"
    return key[:80]


def is_keywords(text: str, loc: str) -> bool:
    if "keywords:" in loc:
        return True
    if text != text.lower():
        return False
    parts = text.split()
    return len(parts) >= 4 and all(re.fullmatch(r"[a-z0-9+]+", p) for p in parts)


def meta_for(key: str, placeholders: dict) -> dict:
    if not placeholders:
        return {}
    return {f"@{key}": {"placeholders": placeholders}}


def build_en() -> OrderedDict:
    arb: OrderedDict = OrderedDict()
    arb["@@locale"] = "en"
    used_keys = set()
    used_text = set()

    for key, en, ph in EXPLICIT:
        arb[key] = en
        used_keys.add(key)
        used_text.add(en)
        if ph:
            arb[f"@{key}"] = {"placeholders": ph}

    # extra common UI strings scraped (complete, non-brand, non-keyword)
    catalog = Path("/tmp/l10n_ui_strings.txt")
    if catalog.exists():
        for line in catalog.read_text().splitlines():
            if "\t" not in line:
                continue
            raw, loc = line.split("\t", 1)
            text = raw.strip("'").replace("\\'", "'").replace('\\"', '"')
            if text.endswith(" ") or text.endswith("\\n"):
                continue  # truncated adjacent-string
            if text in used_text or text in BRANDS:
                continue
            if is_keywords(text, loc):
                continue
            if "$" in text or "{" in text:
                continue
            key = to_key(text)
            n = 2
            base = key
            while key in used_keys:
                key = f"{base}{n}"
                n += 1
            arb[key] = text
            used_keys.add(key)
            used_text.add(text)
    return arb


def write_arb(locale: str, messages: dict) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"app_{locale}.arb"
    # Keep @@locale first
    ordered = OrderedDict()
    ordered["@@locale"] = locale.replace("_", "_")
    if locale == "zh":
        ordered["@@locale"] = "zh"
    elif locale == "zh_TW":
        ordered["@@locale"] = "zh_TW"
    for k, v in messages.items():
        if k == "@@locale":
            continue
        ordered[k] = v
    path.write_text(json.dumps(ordered, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("wrote", path, "keys", sum(1 for k in ordered if not k.startswith("@")))


if __name__ == "__main__":
    en = build_en()
    write_arb("en", en)
    (OUT / "_en_keys.json").write_text(
        json.dumps({k: v for k, v in en.items() if not k.startswith("@")}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
