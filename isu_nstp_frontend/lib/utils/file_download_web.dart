import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<void> saveOrShareFile({
  required List<int> bytes,
  required String filename,
  required String mimeType,
  String? subject,
  String? text,
}) async {
  final parts = <JSAny>[Uint8List.fromList(bytes).toJS].toJS;
  final blob = web.Blob(parts, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..click();
  web.URL.revokeObjectURL(url);
}
