import 'dart:ui';

/// The Zangetsu mark as drawable geometry, split into the three parts the
/// splash animates independently.
///
/// Generated from `assets/brand/zangetsu-mark.svg` (the traced master) with the
/// SVG's own transform baked in, so these coordinates already live in a
/// {0, 0, 512, 512} box — a painter only has to scale that to its size.
///
/// Kept as path data rather than pulling in an SVG package: the traced paths
/// use only M/L/Z, so [parseMarkPath] is a dozen lines and there is nothing an
/// SVG renderer would add. Regenerate if the artwork changes.
class ZangetsuMark {
  ZangetsuMark._();

  /// The box the raw coordinates are expressed in.
  static const double side = 512;

  /// The blade's axis, degrees, measured off the artwork. The splash slides the
  /// blade along this and wipes the other parts perpendicular to it.
  static const double bladeAngleDeg = -35.1;

  static const String _crescent =
      'M86.0,357.8 L84.4,357.2 L82.0,353.8 L73.7,339.0 L64.8,325.5 L60.0,315.5 '
      'L56.6,304.9 L53.7,291.5 L49.8,258.9 L50.3,241.1 L52.2,224.8 L55.2,209.5 '
      'L60.0,191.3 L67.7,171.1 L74.4,157.7 L82.7,144.5 L83.6,144.3 L82.3,147.6 '
      'L74.8,162.0 L69.6,175.9 L67.9,185.5 L62.4,206.1 L60.8,226.3 L61.6,249.8 '
      'L62.3,248.8 L64.3,226.8 L71.5,198.9 L76.3,185.0 L80.6,175.4 L94.5,150.5 '
      'L114.3,123.9 L127.7,110.0 L147.4,94.3 L167.1,81.8 L174.7,78.0 L176.5,78.1 '
      'L175.4,79.1 L144.8,99.7 L131.1,111.4 L117.2,125.9 L99.8,149.1 L94.0,158.7 '
      'L88.4,171.6 L108.1,140.7 L120.8,125.6 L142.4,104.5 L163.7,89.9 L187.2,77.5 '
      'L199.2,72.7 L223.2,65.0 L243.8,62.5 L262.5,62.5 L289.8,66.0 L309.0,71.7 '
      'L330.6,80.4 L347.8,90.4 L354.7,95.4 L354.5,95.9 L333.9,85.6 L322.9,83.0 '
      'L321.0,81.8 L320.3,81.9 L320.9,82.9 L319.1,83.0 L318.5,81.9 L320.0,81.5 '
      'L318.1,79.9 L308.0,77.0 L288.4,73.6 L259.6,73.6 L244.7,75.6 L239.2,77.1 '
      'L251.4,77.4 L252.5,78.1 L251.9,78.7 L231.8,82.3 L213.1,88.5 L187.2,102.4 '
      'L174.2,111.4 L169.5,116.3 L169.5,116.9 L170.4,116.6 L189.1,105.8 L212.6,97.6 '
      'L215.0,98.4 L224.1,95.7 L239.0,93.2 L254.3,93.0 L251.4,94.1 L224.1,99.1 '
      'L185.8,115.8 L170.7,126.5 L169.4,128.5 L169.9,129.0 L179.0,122.6 '
      'L179.4,124.1 L177.7,124.6 L178.1,125.1 L177.1,126.2 L175.7,126.1 '
      'L175.8,127.0 L159.6,140.9 L156.7,141.9 L155.9,143.8 L157.5,143.7 '
      'L157.6,144.3 L156.6,145.7 L144.0,159.4 L134.8,172.6 L127.6,185.0 '
      'L122.3,196.5 L122.0,198.0 L123.9,197.5 L124.0,199.4 L119.0,210.0 '
      'L115.6,220.5 L111.7,244.0 L112.6,247.8 L111.2,254.6 L111.2,262.7 '
      'L113.2,285.2 L118.5,306.8 L126.4,326.5 L126.9,329.4 L117.7,333.8 '
      'L114.8,331.1 L102.3,325.4 L101.1,339.0 L102.4,347.1 L95.1,353.0 L93.7,353.1 '
      'L86.4,341.8 L77.2,322.2 L69.6,298.2 L67.0,284.3 L66.5,282.9 L65.8,282.9 '
      'L66.1,292.9 L69.1,307.8 L79.2,339.9 L86.2,354.8 L86.0,357.8 ZM131.1,326.2 '
      'L130.0,326.0 L125.2,315.5 L121.8,305.4 L119.0,292.9 L117.9,286.7 '
      'L118.4,260.8 L121.4,241.6 L127.1,220.5 L131.9,208.1 L137.7,196.1 '
      'L143.6,187.9 L133.3,211.9 L129.5,224.4 L127.5,233.5 L125.6,251.2 '
      'L125.6,266.5 L126.9,271.3 L130.0,293.4 L139.3,319.8 L138.8,320.9 '
      'L131.1,326.2 ZM69.3,325.0 L64.3,311.1 L58.5,285.2 L56.5,262.2 L54.9,255.3 '
      'L54.6,269.9 L55.6,281.9 L59.5,302.0 L64.8,318.8 L66.7,322.7 L68.8,325.2 '
      'L69.3,325.0 ZM259.1,449.4 L237.5,449.0 L218.4,446.5 L194.4,440.8 '
      'L177.1,434.5 L159.4,425.4 L155.1,420.8 L135.2,407.0 L128.2,400.5 '
      'L128.5,398.4 L132.1,395.4 L133.5,395.4 L140.7,401.0 L151.2,406.1 '
      'L139.7,393.8 L137.6,390.3 L139.2,388.7 L154.1,381.4 L155.5,381.5 '
      'L184.8,396.0 L181.6,392.2 L172.1,385.5 L163.1,376.8 L163.2,375.3 '
      'L175.7,367.0 L184.3,374.1 L194.4,380.3 L204.5,385.6 L214.0,389.4 '
      'L234.2,395.7 L258.2,399.1 L280.2,398.7 L291.7,397.1 L306.6,393.8 '
      'L327.2,386.1 L337.3,380.8 L353.1,371.0 L352.8,372.0 L344.5,378.9 '
      'L320.5,394.7 L309.5,400.5 L293.8,407.0 L313.8,402.4 L336.3,393.8 '
      'L349.7,386.6 L366.2,374.4 L384.3,355.9 L396.0,340.4 L397.7,338.8 '
      'L399.3,339.0 L403.1,334.6 L412.7,320.3 L421.3,303.5 L426.6,288.1 '
      'L431.6,265.1 L432.7,262.7 L432.5,275.2 L428.5,294.8 L425.2,307.8 '
      'L418.5,325.5 L408.9,345.2 L388.3,372.5 L373.2,387.6 L364.3,395.1 '
      'L349.3,405.3 L335.8,412.5 L320.0,419.2 L299.4,425.9 L272.8,432.0 '
      'L283.1,431.7 L296.0,429.7 L309.0,426.4 L331.5,418.7 L349.3,410.7 '
      'L352.1,410.5 L366.5,401.9 L388.1,385.9 L385.4,389.8 L369.1,403.7 '
      'L348.8,417.7 L331.0,427.3 L306.6,436.9 L289.3,440.8 L269.7,443.2 '
      'L249.5,443.2 L213.7,438.7 L220.3,440.8 L224.6,440.8 L226.0,442.7 '
      'L237.5,445.1 L268.2,447.8 L268.2,448.5 L259.1,449.4 ZM80.3,362.0 L76.8,358.1 '
      'L68.6,343.7 L63.8,334.2 L62.5,327.5 L80.9,357.7 L81.5,360.5 L80.3,362.0 Z ';

  static const String _blade =
      'M26.6,435.5 L25.5,435.3 L27.3,432.9 L46.4,418.6 L86.7,385.0 L92.1,379.7 '
      'L116.7,362.2 L119.3,358.6 L115.5,350.5 L116.1,348.5 L119.1,345.5 '
      'L120.5,345.5 L127.3,351.6 L129.2,352.5 L132.1,352.5 L148.4,340.2 '
      'L160.8,332.4 L277.3,252.0 L331.0,216.5 L341.1,211.1 L355.5,201.2 '
      'L380.0,186.6 L399.1,173.9 L404.0,171.6 L399.8,175.9 L386.0,186.5 '
      'L362.9,206.1 L298.9,255.2 L214.5,316.6 L150.1,360.5 L145.8,364.8 '
      'L147.4,372.6 L143.6,371.2 L140.2,368.5 L134.0,372.7 L130.6,371.8 '
      'L128.2,372.9 L98.5,395.7 L97.0,394.4 L95.6,394.9 L26.6,435.5 Z ';

  static const String _slash =
      'M220.3,268.6 L220.8,266.8 L226.0,262.6 L353.6,171.0 L403.9,137.4 '
      'L445.6,111.0 L483.5,88.5 L486.4,87.7 L483.2,91.1 L469.4,101.1 L431.5,131.8 '
      'L394.3,159.3 L365.6,179.4 L319.5,209.2 L258.6,244.8 L220.3,268.6 Z ';

  static Path? _c, _b, _s;

  /// The crescent and its brush flicks — everything white except the blade.
  static Path get crescent => _c ??= parseMarkPath(_crescent);

  /// The long diagonal blade, on its own so it can be thrown in separately.
  static Path get blade => _b ??= parseMarkPath(_blade);

  /// The red slash.
  static Path get slash => _s ??= parseMarkPath(_slash);

  /// Minimal parser for the only three commands the traced artwork uses.
  /// Anything else is deliberately unsupported — it cannot occur here, and
  /// silently mis-drawing would be worse than failing loudly.
  static Path parseMarkPath(String d) {
    final path = Path()..fillType = PathFillType.evenOdd;
    for (final token in d.split(' ')) {
      if (token.isEmpty) continue;
      final cmd = token[0];
      if (cmd == 'Z') {
        path.close();
        continue;
      }
      final xy = token.substring(1).split(',');
      final x = double.parse(xy[0]);
      final y = double.parse(xy[1]);
      if (cmd == 'M') {
        path.moveTo(x, y);
      } else if (cmd == 'L') {
        path.lineTo(x, y);
      } else {
        throw FormatException('unsupported path command', d);
      }
    }
    return path;
  }
}
