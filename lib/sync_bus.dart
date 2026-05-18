import 'package:flutter/foundation.dart';

/// Notifies listeners after a remote sync changed Hive-backed data.
class SyncBus extends ChangeNotifier {
  SyncBus._();
  static final SyncBus instance = SyncBus._();

  void bump() => notifyListeners();
}

/// Rebuilds [AppShell] when cloud login skip flag changes (e.g. from Settings).
class CloudLoginGateNotifier extends ChangeNotifier {
  CloudLoginGateNotifier._();
  static final CloudLoginGateNotifier instance = CloudLoginGateNotifier._();

  void refresh() => notifyListeners();
}
