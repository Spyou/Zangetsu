/// Tracks whether a detail route is covered by another page.
///
/// A covered detail trailer must release its native player before a fullscreen
/// player is created. The trailer is recreated when this route is uncovered.
class TrailerRouteLifecycle {
  bool _isCovered = false;
  bool _isDisposing = false;
  bool _isRouteSettled = true;

  bool get isCovered => _isCovered;

  bool get canCreatePlayer => _isRouteSettled && !_isCovered && !_isDisposing;

  void setRouteSettled(bool settled) => _isRouteSettled = settled;

  bool get canUpdateUi => !_isDisposing;

  void beginDispose() => _isDisposing = true;

  /// Marks the route covered; returns true only for the first cover event.
  bool cover() {
    if (_isDisposing) return false;
    if (_isCovered) return false;
    _isCovered = true;
    return true;
  }

  /// Marks the route visible again; returns true only after a cover event.
  bool uncover() {
    if (_isDisposing) return false;
    if (!_isCovered) return false;
    _isCovered = false;
    return true;
  }
}
