import 'package:flutter/material.dart';
import 'package:trypr/widgets/modern_widgets.dart';

/// Quick stats card for destination planning overview
class DestinationStatsCard extends StatelessWidget {
  final String label;
  final int count;
  final IconData icon;
  final VoidCallback? onTap;

  const DestinationStatsCard({
    super.key,
    required this.label,
    required this.count,
    required this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        borderRadius: 8,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 28, color: const Color(0xFF00695C)),
            const SizedBox(height: 8),
            Text(
              count.toString(),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Budget tracker for accommodations and activities
class BudgetTrackerWidget extends StatelessWidget {
  final double totalBudget;
  final double spent;
  final String currency;

  const BudgetTrackerWidget({
    super.key,
    required this.totalBudget,
    required this.spent,
    this.currency = '\$',
  });

  @override
  Widget build(BuildContext context) {
    final remaining = totalBudget - spent;
    final percentage = totalBudget > 0 ? (spent / totalBudget) : 0.0;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      borderRadius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Budget Overview',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildBudgetStat('Total', '$currency$totalBudget'),
              _buildBudgetStat('Spent', '$currency${spent.toStringAsFixed(2)}'),
              _buildBudgetStat(
                'Remaining',
                '$currency${remaining.toStringAsFixed(2)}',
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: percentage,
              minHeight: 8,
              backgroundColor: Colors.grey.shade300,
              valueColor: AlwaysStoppedAnimation<Color>(
                percentage > 0.9
                    ? Colors.red
                    : percentage > 0.75
                    ? Colors.orange
                    : Colors.green,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(percentage * 100).toStringAsFixed(1)}% of budget used',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildBudgetStat(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ],
    );
  }
}

/// Activity/Item checklist for day planning
class DailyChecklistWidget extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final ValueChanged<List<Map<String, dynamic>>>? onChanged;

  const DailyChecklistWidget({super.key, required this.items, this.onChanged});

  @override
  State<DailyChecklistWidget> createState() => _DailyChecklistWidgetState();
}

class _DailyChecklistWidgetState extends State<DailyChecklistWidget> {
  late List<Map<String, dynamic>> _items;

  @override
  void initState() {
    super.initState();
    _items = List<Map<String, dynamic>>.from(widget.items);
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(12),
      borderRadius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Daily Checklist',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No items yet',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _items.length,
              itemBuilder: (ctx, i) {
                final item = _items[i];
                return CheckboxListTile(
                  value: item['completed'] ?? false,
                  onChanged: (v) {
                    setState(() {
                      _items[i]['completed'] = v ?? false;
                      widget.onChanged?.call(_items);
                    });
                  },
                  title: Text(item['title'] ?? 'Item'),
                  subtitle:
                      item['description'] != null &&
                              (item['description'] as String).isNotEmpty
                          ? Text(item['description'] ?? '')
                          : null,
                );
              },
            ),
        ],
      ),
    );
  }
}

/// Map/Location preview card
class LocationPreviewCard extends StatelessWidget {
  final String locationName;
  final double? latitude;
  final double? longitude;
  final String? imageUrl;
  final VoidCallback? onTap;

  const LocationPreviewCard({
    super.key,
    required this.locationName,
    this.latitude,
    this.longitude,
    this.imageUrl,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        borderRadius: 12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (imageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  imageUrl!,
                  height: 120,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder:
                      (_, __, ___) => Container(
                        height: 120,
                        color: Colors.grey.shade300,
                        child: const Center(
                          child: Icon(Icons.image_not_supported),
                        ),
                      ),
                ),
              )
            else
              Container(
                height: 120,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: const Color(0xFF00695C).withOpacity(0.1),
                ),
                child: const Center(child: Icon(Icons.place, size: 40)),
              ),
            const SizedBox(height: 8),
            Text(locationName, style: Theme.of(context).textTheme.titleMedium),
            if (latitude != null && longitude != null)
              Text(
                '$latitude, $longitude',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

/// Timeline view for itinerary
class TimelineActivityWidget extends StatelessWidget {
  final List<Map<String, dynamic>> activities;
  final bool isCompact;

  const TimelineActivityWidget({
    super.key,
    required this.activities,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (activities.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No activities planned',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }

    return Column(
      children:
          activities.asMap().entries.map((entry) {
            final idx = entry.key;
            final activity = entry.value;
            final isLast = idx == activities.length - 1;

            return Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      children: [
                        Container(
                          width: 16,
                          height: 16,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF00695C),
                          ),
                        ),
                        if (!isLast)
                          Container(
                            width: 2,
                            height: isCompact ? 60 : 80,
                            color: Colors.grey.shade300,
                          ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (activity['time'] != null &&
                              (activity['time'] as String).isNotEmpty)
                            Text(
                              activity['time'] as String,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          Text(
                            activity['title'] ?? 'Activity',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          if (activity['description'] != null &&
                              (activity['description'] as String).isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                activity['description'] as String,
                                style: Theme.of(context).textTheme.bodySmall,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (!isLast) const SizedBox(height: 8),
              ],
            );
          }).toList(),
    );
  }
}
