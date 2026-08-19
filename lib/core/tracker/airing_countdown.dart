/// How long until [at]: `2d 3h` compact, or `2 days 3 hours` when [long].
///
/// Shared so the detail screen and the tracker sheet can't drift into two
/// different ways of saying the same thing. Compact stays the default because
/// the sheet's row is narrow — only the detail line, which has a whole row to
/// itself, asks for the written-out form.
///
/// Coarse on purpose: the airing time is only accurate to the minute, so a
/// seconds countdown would tick smoothly and still be a minute out.
String airsIn(DateTime at, {bool long = false}) {
  final d = at.difference(DateTime.now());
  // Already aired but the tracker hasn't rolled over to the next episode yet,
  // which it does a little after broadcast.
  if (d.isNegative) return 'now';
  final days = d.inDays;
  final hours = d.inHours % 24;
  final mins = d.inMinutes % 60;
  if (!long) {
    if (days > 0) return '${days}d ${hours}h';
    if (hours > 0) return '${hours}h ${mins}m';
    return '${mins}m';
  }
  if (days > 0) return '${_plural(days, 'day')} ${_plural(hours, 'hour')}';
  if (hours > 0) return '${_plural(hours, 'hour')} ${_plural(mins, 'minute')}';
  return _plural(mins, 'minute');
}

String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
