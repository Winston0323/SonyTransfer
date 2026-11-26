/// One mass-storage volume on a cable-connected Sony body — usually one SD
/// card. With USB LUN set to Multi the camera exposes each slot (plus a tiny
/// PMHOME volume we ignore) as its own card.
class UsbCard {
  const UsbCard({
    required this.id,
    required this.label,
    required this.jpegCount,
    required this.rawCount,
    required this.hasDcim,
    required this.suggested,
  });

  factory UsbCard.fromMap(Map<dynamic, dynamic> map) => UsbCard(
        id: map['id'] as int? ?? 0,
        label: map['label'] as String? ?? 'Card',
        jpegCount: map['jpegCount'] as int? ?? 0,
        rawCount: map['rawCount'] as int? ?? 0,
        hasDcim: map['hasDcim'] == true,
        suggested: map['suggested'] == true,
      );

  final int id;
  final String label;
  final int jpegCount;
  final int rawCount;
  final bool hasDcim;

  /// True for the volume that looks like the JPEG card — most JPEGs, and on
  /// a tie, fewer RAWs. The transfer screen selects this by default.
  final bool suggested;
}

/// Pure helper so the default pick is unit-testable without USB hardware.
int? suggestedUsbCardId(Iterable<UsbCard> cards) {
  UsbCard? best;
  for (final card in cards) {
    if (card.jpegCount <= 0) continue;
    if (best == null ||
        card.jpegCount > best.jpegCount ||
        (card.jpegCount == best.jpegCount && card.rawCount < best.rawCount)) {
      best = card;
    }
  }
  return best?.id;
}
