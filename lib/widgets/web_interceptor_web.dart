// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/widgets.dart';
import 'package:trypr/utils/platform_view_registry.dart';

/// Web implementation – creates a real (visible-to-compositor) platform-view
/// `<div>` that sits above the Globe iframe in the browser z-order.
///
/// The `<div>` is transparent, has `pointer-events: auto`, and prevents
/// `mousedown` default to avoid stealing focus from Flutter text inputs.
class WebInterceptor extends StatefulWidget {
  final Widget child;
  const WebInterceptor({super.key, required this.child});

  @override
  State<WebInterceptor> createState() => _WebInterceptorState();
}

class _WebInterceptorState extends State<WebInterceptor> {
  static int _counter = 0;
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _counter++;
    _viewType = 'web-interceptor-$_counter';

    registerHtmlElementViewFactory(_viewType, (int viewId) {
      final div =
          html.DivElement()
            ..style.width = '100%'
            ..style.height = '100%'
            ..style.position = 'absolute'
            ..style.top = '0'
            ..style.left = '0'
            ..style.pointerEvents = 'auto';

      // Block mousedown default to prevent focus stealing from Flutter inputs.
      div.addEventListener('mousedown', (event) {
        (event as html.MouseEvent).preventDefault();
      });

      return div;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(child: HtmlElementView(viewType: _viewType)),
        widget.child,
      ],
    );
  }
}
