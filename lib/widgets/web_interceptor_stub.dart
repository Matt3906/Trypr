import 'package:flutter/widgets.dart';

/// Stub no-op for non-web platforms.
class WebInterceptor extends StatelessWidget {
  final Widget child;
  const WebInterceptor({super.key, required this.child});

  @override
  Widget build(BuildContext context) => child;
}
