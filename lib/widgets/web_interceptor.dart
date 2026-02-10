/// A platform-view based click interceptor for Flutter web (CanvasKit).
///
/// Unlike `pointer_interceptor` (which uses `HtmlElementView.fromTagName`
/// with `isVisible: false` and can fail in CanvasKit compositing when layered
/// above an iframe), this creates a *visible* (but transparent) platform-view
/// `<div>` that reliably sits above the Globe iframe in the browser stacking
/// context.
///
/// On non-web platforms this is a no-op wrapper.
library;

export 'web_interceptor_stub.dart'
    if (dart.library.html) 'web_interceptor_web.dart';
