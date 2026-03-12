import 'pick_file_data_url_stub.dart'
    if (dart.library.html) 'pick_file_data_url_web.dart';

typedef PickedFileData = ({String fileName, String dataUrl});

/// Picks a single file and returns the selected file name + data URL payload.
///
/// On non-web platforms this returns null unless a native picker is added.
Future<PickedFileData?> pickFileDataUrl({String accept = '*/*'}) =>
    pickFileDataUrlImpl(accept: accept);
