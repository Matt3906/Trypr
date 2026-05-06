import 'package:flutter/material.dart';

enum PortageSegmentStatus {
  idle,
  queued,
  loading,
  cached,
  ready,
  fallback,
  error,
}

class PortageSegmentBuilder extends StatelessWidget {
  final int segmentNumber;
  final String title;
  final PortageSegmentStatus status;
  final double? distanceMeters;
  final double? durationSeconds;
  final String? message;
  final VoidCallback? onRetry;

  const PortageSegmentBuilder({
    super.key,
    required this.segmentNumber,
    required this.title,
    required this.status,
    this.distanceMeters,
    this.durationSeconds,
    this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = switch (status) {
      PortageSegmentStatus.ready ||
      PortageSegmentStatus.cached => const Color(0xFF1B5E20),
      PortageSegmentStatus.loading ||
      PortageSegmentStatus.queued => colorScheme.primary,
      PortageSegmentStatus.fallback => const Color(0xFFB26A00),
      PortageSegmentStatus.error => colorScheme.error,
      PortageSegmentStatus.idle => Colors.black54,
    };
    final statusLabel = switch (status) {
      PortageSegmentStatus.ready => 'Loaded',
      PortageSegmentStatus.cached => 'Cached',
      PortageSegmentStatus.loading => 'Loading',
      PortageSegmentStatus.queued => 'Queued',
      PortageSegmentStatus.fallback => 'Fallback route',
      PortageSegmentStatus.error => 'Needs retry',
      PortageSegmentStatus.idle => 'Waiting',
    };
    final metricParts = <String>[];
    if (distanceMeters != null && distanceMeters! > 0) {
      metricParts.add('${(distanceMeters! / 1000.0).toStringAsFixed(1)} km');
    }
    if (durationSeconds != null && durationSeconds! > 0) {
      final minutes = (durationSeconds! / 60.0).round();
      metricParts.add('$minutes min');
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(minHeight: 84),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 32, child: Center(child: _leadingIcon(statusColor))),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Segment $segmentNumber',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    statusLabel,
                    if (metricParts.isNotEmpty) metricParts.join(' • '),
                    if (message != null && message!.trim().isNotEmpty) message!,
                  ].join(' • '),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          if (status == PortageSegmentStatus.error && onRetry != null) ...[
            const SizedBox(width: 8),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ],
      ),
    );
  }

  Widget _leadingIcon(Color color) {
    if (status == PortageSegmentStatus.loading ||
        status == PortageSegmentStatus.queued) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      );
    }
    if (status == PortageSegmentStatus.error) {
      return Icon(Icons.error_outline, size: 20, color: color);
    }
    if (status == PortageSegmentStatus.fallback) {
      return Icon(Icons.route, size: 20, color: color);
    }
    if (status == PortageSegmentStatus.ready ||
        status == PortageSegmentStatus.cached) {
      return Icon(Icons.check_circle_outline, size: 20, color: color);
    }
    return Icon(Icons.schedule, size: 20, color: color);
  }
}
