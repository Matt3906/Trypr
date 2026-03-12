// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

Future<({String fileName, String dataUrl})?> pickFileDataUrlImpl({
  String accept = '*/*',
}) async {
  final input = html.FileUploadInputElement();
  input.accept = accept.trim().isEmpty ? '*/*' : accept.trim();
  input.multiple = false;

  final completer = Completer<({String fileName, String dataUrl})?>();

  void completeOnce(({String fileName, String dataUrl})? v) {
    if (completer.isCompleted) return;
    completer.complete(v);
  }

  input.onChange.listen((_) {
    final files = input.files;
    if (files == null || files.isEmpty) {
      completeOnce(null);
      return;
    }

    final file = files.first;
    final reader = html.FileReader();
    reader.readAsDataUrl(file);

    reader.onError.listen((_) => completeOnce(null));
    reader.onLoadEnd.listen((_) {
      final result = reader.result;
      if (result is! String || result.trim().isEmpty) {
        completeOnce(null);
        return;
      }
      completeOnce((fileName: file.name, dataUrl: result));
    });
  });

  // If the user closes the picker without choosing a file.
  Timer(const Duration(seconds: 30), () => completeOnce(null));

  input.click();
  return completer.future;
}
