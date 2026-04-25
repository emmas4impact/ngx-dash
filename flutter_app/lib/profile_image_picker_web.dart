// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';

import 'dart:html' as html;

class PickedProfileImage {
  const PickedProfileImage({
    required this.dataUrl,
    required this.mimeType,
    required this.bytes,
  });

  final String dataUrl;
  final String mimeType;
  final List<int> bytes;
}

Future<PickedProfileImage?> pickProfileImageForWeb() async {
  final input = html.FileUploadInputElement()..accept = 'image/*';
  input.click();
  await input.onChange.first;

  final file = input.files?.isNotEmpty == true ? input.files!.first : null;
  if (file == null) {
    return null;
  }

  final reader = html.FileReader();
  final completer = Completer<PickedProfileImage?>();

  reader.onError.first.then((_) {
    if (!completer.isCompleted) {
      completer.completeError(
        reader.error ?? StateError('Could not read the selected image.'),
      );
    }
  });

  reader.onLoad.first.then((_) {
    if (completer.isCompleted) return;
    final result = reader.result;
    if (result is! String || !result.startsWith('data:')) {
      completer.completeError(
        StateError('Could not load the selected image data.'),
      );
      return;
    }

    final commaIndex = result.indexOf(',');
    if (commaIndex < 0) {
      completer.completeError(StateError('Invalid image data URL.'));
      return;
    }

    final mimeMatch = RegExp(r'^data:([^;]+);base64,').firstMatch(result);
    final mimeType = mimeMatch?.group(1) ?? 'image/jpeg';
    final bytes = base64Decode(result.substring(commaIndex + 1));
    completer.complete(
      PickedProfileImage(dataUrl: result, mimeType: mimeType, bytes: bytes),
    );
  });

  reader.readAsDataUrl(file);
  return completer.future;
}
