import 'package:flutter/widgets.dart';

/// Logs navigation events for debugging.
class LoggingObserver extends NavigatorObserver {
  @override
  void didPush(Route route, Route? previousRoute) {
    debugPrint('Navigated to: \${route.settings.name}');
  }
}
