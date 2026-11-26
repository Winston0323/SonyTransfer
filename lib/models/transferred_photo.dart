import 'dart:io';

import 'package:path/path.dart' as p;

/// A shot already sitting in the app's local download cache from a previous
/// transfer.
///
/// The album screen does not read this type. It points the image album at
/// the same cache folder and lets that library list the files. This type is
/// the listing the transfer flow uses to skip shots already downloaded.
class TransferredPhoto {
  const TransferredPhoto({required this.file, required this.takenAt});

  final File file;

  /// When the shot was taken. The transfer stamps each downloaded file's
  /// modification time with the capture date the camera reported, so this
  /// survives without a separate database. Files whose shot had no date —
  /// or that were transferred before the app started stamping — carry the
  /// time they were downloaded instead.
  final DateTime takenAt;

  String get id => file.path;

  String get fileName => p.basename(file.path);
}
