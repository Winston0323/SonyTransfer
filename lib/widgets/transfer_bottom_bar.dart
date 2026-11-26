import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/network_binding.dart';
import '../services/transfer_service.dart';

/// Shared transfer action bar used by Wi-Fi and USB browse screens.
class TransferBottomBar extends StatelessWidget {
  const TransferBottomBar({
    super.key,
    required this.visible,
    required this.transferring,
    required this.selectedCount,
    required this.queueLength,
    required this.done,
    required this.progress,
    required this.onDownload,
    required this.onCancel,
    this.linkInfo,
  });

  /// Hidden while the camera is not connected yet.
  final bool visible;
  final bool transferring;
  final int selectedCount;

  /// Size of the batch currently transferring (or about to).
  final int queueLength;
  final int done;
  final ValueListenable<TransferProgress?> progress;
  final VoidCallback onDownload;
  final VoidCallback onCancel;

  /// Wi-Fi radio stats; omit on USB.
  final WifiLinkInfo? linkInfo;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (transferring) ...[
              ValueListenableBuilder<TransferProgress?>(
                valueListenable: progress,
                builder: (context, value, _) => _CurrentShot(
                  progress: value,
                  done: done,
                  outOf: queueLength == 0 ? selectedCount : queueLength,
                  linkInfo: linkInfo,
                ),
              ),
              const SizedBox(height: 12),
            ],
            SizedBox(
              width: double.infinity,
              child: transferring
                  ? OutlinedButton.icon(
                      onPressed: onCancel,
                      icon: const Icon(Icons.stop),
                      label: const Text('Cancel'),
                    )
                  : FilledButton.icon(
                      onPressed: selectedCount == 0 ? null : onDownload,
                      icon: const Icon(Icons.download),
                      label: Text(
                        selectedCount == 0
                            ? 'Select shots to transfer'
                            : 'Transfer $selectedCount selected',
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentShot extends StatelessWidget {
  const _CurrentShot({
    required this.progress,
    required this.done,
    required this.outOf,
    required this.linkInfo,
  });

  final TransferProgress? progress;
  final int done;
  final int outOf;
  final WifiLinkInfo? linkInfo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = progress;
    final expected = value?.total ?? 0;
    final current =
        value?.position ?? (done + 1).clamp(1, outOf == 0 ? 1 : outOf);
    final link = linkInfo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                value?.item.fileName ?? 'Starting…',
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$current / $outOf',
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: expected <= 0
              ? null
              : (value!.received / expected).clamp(0.0, 1.0),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                expected <= 0
                    ? ''
                    : '${formatBytes(value!.received)} of '
                        '${formatBytes(expected)}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.hintColor),
              ),
            ),
            if (value != null && value.bytesPerSecond > 0)
              Text(
                link?.linkSpeedMbps == null
                    ? '${formatBytes(value.bytesPerSecond.round())}/s'
                    : '${formatBytes(value.bytesPerSecond.round())}/s · '
                        'link ${link!.linkSpeedMbps}Mbps',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
          ],
        ),
        if (link != null && link.isWeakSignal) ...[
          const SizedBox(height: 4),
          Text(
            'Weak Wi-Fi signal (${link.rssiDbm} dBm) — move closer to the '
            'camera for a faster transfer.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ],
    );
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
