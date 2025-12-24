import 'dart:async';
import 'dart:html' as html;

Future<String?> pickImageDataUrlImpl() async {
  final input = html.FileUploadInputElement();
  input.accept = 'image/*';
  input.multiple = false;

  final completer = Completer<String?>();

  void completeOnce(String? v) {
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
      completeOnce(result is String ? result : null);
    });
  });

  // If the user closes the picker without selecting a file, we won't get
  // an onChange event reliably. Add a small timeout fallback.
  Timer(const Duration(seconds: 30), () => completeOnce(null));

  input.click();
  return completer.future;
}
