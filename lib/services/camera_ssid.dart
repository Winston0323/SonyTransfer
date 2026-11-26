/// Sony camera access points are named `DIRECT-…`, sometimes with the body
/// name (`ILCE-7RM3`) in the SSID.
bool looksLikeCameraSsid(String ssid) {
  final upper = ssid.toUpperCase();
  return upper.startsWith('DIRECT-') ||
      upper.contains('ILCE') ||
      upper.contains('DSC-') ||
      upper.contains('ZV-') ||
      (upper.contains('SONY') && upper.contains('CAM'));
}
