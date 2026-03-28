import 'package:flutter/material.dart';

class TransitLegTabsCard extends StatefulWidget {
  final String originName;
  final String destinationName;
  final List<Map<String, dynamic>> steps;
  final String? arrivalStopName;
  final ValueChanged<Map<String, dynamic>>? onStepSelected;

  const TransitLegTabsCard({
    super.key,
    required this.originName,
    required this.destinationName,
    required this.steps,
    this.arrivalStopName,
    this.onStepSelected,
  });

  @override
  State<TransitLegTabsCard> createState() => _TransitLegTabsCardState();
}

class _TransitLegTabsCardState extends State<TransitLegTabsCard> {
  int _selectedStepIndex = 0;

  @override
  void didUpdateWidget(covariant TransitLegTabsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final maxIndex = _visibleSteps.length - 1;
    if (_selectedStepIndex > maxIndex) {
      _selectedStepIndex = maxIndex < 0 ? 0 : maxIndex;
    }
  }

  List<Map<String, dynamic>> get _visibleSteps {
    return widget.steps
        .where((step) {
          final tabLabel = (step['tabLabel'] ?? '').toString().trim();
          final headline = (step['headline'] ?? '').toString().trim();
          return tabLabel.isNotEmpty || headline.isNotEmpty;
        })
        .take(6)
        .toList(growable: false);
  }

  void _selectStep(
    List<Map<String, dynamic>> visibleSteps,
    int index, {
    bool notify = true,
  }) {
    if (index < 0 || index >= visibleSteps.length) return;
    setState(() => _selectedStepIndex = index);
    if (notify) {
      widget.onStepSelected?.call(
        Map<String, dynamic>.from(visibleSteps[index]),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleSteps = _visibleSteps;
    if (visibleSteps.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final title = '${widget.originName} to ${widget.destinationName}';
    final arrivalLine =
        (widget.arrivalStopName ?? '').trim().isEmpty
            ? 'Train leg'
            : 'Train leg • arrive at ${widget.arrivalStopName!.trim()}';
    final safeIndex = _selectedStepIndex.clamp(0, visibleSteps.length - 1);
    final selectedStep = visibleSteps[safeIndex];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF1F8F5), Color(0xFFF7FAFE)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x2600897B)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF00897B).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.directions_transit_rounded,
                  color: Color(0xFF00695C),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      arrivalLine,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF4B5563),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0x1A000000)),
                ),
                child: Text(
                  '${visibleSteps.length} tabs',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0F766E),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < visibleSteps.length; i++)
                _TransitStepChip(
                  selected: i == safeIndex,
                  icon: _TransitLegStepPane.iconForMode(
                    (visibleSteps[i]['mode'] ?? '')
                        .toString()
                        .trim()
                        .toLowerCase(),
                  ),
                  label: _tabLabelForStep(visibleSteps[i]),
                  onTap: () => _selectStep(visibleSteps, i),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap:
                  () => widget.onStepSelected?.call(
                    Map<String, dynamic>.from(selectedStep),
                  ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: KeyedSubtree(
                  key: ValueKey<String>(
                    [
                      (selectedStep['tabLabel'] ?? '').toString(),
                      (selectedStep['headline'] ?? '').toString(),
                    ].join('|'),
                  ),
                  child: _TransitLegStepPane(step: selectedStep),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _tabLabelForStep(Map<String, dynamic> step) {
    final raw = (step['tabLabel'] ?? '').toString().trim();
    if (raw.isEmpty) return 'Step';
    if (raw.length <= 16) return raw;
    return '${raw.substring(0, 15)}…';
  }
}

class _TransitStepChip extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _TransitStepChip({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color:
                selected
                    ? const Color(0xFF0F766E)
                    : Colors.white.withValues(alpha: 0.84),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  selected ? const Color(0xFF0F766E) : const Color(0x14000000),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? Colors.white : const Color(0xFF4B5563),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : const Color(0xFF374151),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TransitLegStepPane extends StatelessWidget {
  final Map<String, dynamic> step;

  const _TransitLegStepPane({required this.step});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = (step['mode'] ?? '').toString().trim().toLowerCase();
    final headline = (step['headline'] ?? '').toString().trim();
    final detail = (step['detail'] ?? '').toString().trim();
    final caption = (step['caption'] ?? '').toString().trim();
    final lineColor = _parseHexColor((step['lineColor'] ?? '').toString());

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x16000000)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: (lineColor ?? const Color(0xFF0F766E)).withValues(
                alpha: 0.14,
              ),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              iconForMode(mode),
              color: lineColor ?? const Color(0xFF0F766E),
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  headline.isEmpty ? 'Transit step' : headline,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF111827),
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF374151),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (caption.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF374151),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData iconForMode(String mode) {
    switch (mode) {
      case 'walking':
      case 'walk':
        return Icons.directions_walk_rounded;
      case 'bicycling':
      case 'bike':
      case 'biking':
        return Icons.directions_bike_rounded;
      case 'transit':
      case 'train':
        return Icons.train_rounded;
      default:
        return Icons.alt_route_rounded;
    }
  }

  static Color? _parseHexColor(String hex) {
    final value = hex.trim().replaceAll('#', '');
    if (value.length != 6) return null;
    try {
      return Color(int.parse('FF$value', radix: 16));
    } catch (_) {
      return null;
    }
  }
}
