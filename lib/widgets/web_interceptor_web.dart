import 'package:flutter/widgets.dart';

/// Web implementation – pass-through wrapper.
///
/// Keeping this a no-op avoids platform-view layering issues that can swallow
/// pointer events in some CanvasKit web setups.
class WebInterceptor extends StatelessWidget {
  final Widget child;
  const WebInterceptor({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
