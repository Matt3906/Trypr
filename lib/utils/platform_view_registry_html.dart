import 'dart:ui_web' as ui_web;

void registerHtmlElementViewFactory(String viewType, dynamic Function(int) viewFactory) {
  ui_web.platformViewRegistry.registerViewFactory(viewType, viewFactory);
}
