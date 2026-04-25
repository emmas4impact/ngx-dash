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

Future<PickedProfileImage?> pickProfileImageForWeb() async => null;
