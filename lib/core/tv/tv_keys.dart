import 'package:flutter/services.dart';

/// Keys that count as "OK"/confirm on a TV remote or D-pad.
///
/// NOTE: this is `final`, not `const`, on purpose. `LogicalKeyboardKey`
/// overrides `==`/`hashCode`, so it lacks "primitive equality" and cannot be a
/// `const` set element (Dart error `const_set_element_not_primitive_equality`).
/// Do not "fix" this to `const` — it will not compile.
final Set<LogicalKeyboardKey> okKeys = {
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.gameButtonA,
};
