import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/widgets/modern_widgets.dart';

/// Destination Detail Screen V3: Fixed persistence, week view, time picker, travel categories
class DestinationDetailScreen extends StatefulWidget {
  final String tripId;
  final int destinationIndex;
  final Map<String, dynamic> destination;
  final String tripRef;
  final String? userId;

  const DestinationDetailScreen({
    super.key,
    required this.tripId,
    required this.destinationIndex,
    required this.destination,
    required this.tripRef,
    this.userId,
  });

  @override
  State<DestinationDetailScreen> createState() =>
      _DestinationDetailScreenState();
}

class _DestinationDetailScreenState extends State<DestinationDetailScreen>
    with TickerProviderStateMixin {
  late TabController _mainTabController;
  late TabController _weekTabController;
  late Map<String, dynamic> _destData;
  bool _saving = false;
  late int _dayCount;
  late int _weekCount;

  // Travel-themed categories with colors
  static const travelCategories = {
    'Hiking': Color(0xFF2E7D32), // Green
    'Biking': Color(0xFF1565C0), // Blue
    'Walking': Color(0xFF00796B), // Teal
    'Museum': Color(0xFF6A1B9A), // Purple
    'Sightseeing': Color(0xFFF57C00), // Orange
    'Exploring': Color(0xFFC62828), // Red
    'Restaurant': Color(0xFFD32F2F), // Dark Red
    'Shopping': Color(0xFF7B1FA2), // Deep Purple
    'Photography': Color(0xFF0277BD), // Light Blue
    'Adventure': Color(0xFFFBC02D), // Amber
  };

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    _destData = Map<String, dynamic>.from(widget.destination);
    _dayCount = _calculateDayCount();
    _weekCount = (_dayCount / 7).ceil();
    _mainTabController = TabController(length: 3, vsync: this);
    _weekTabController = TabController(
      length: _weekCount > 0 ? _weekCount : 1,
      vsync: this,
    );
    _initializeItinerary();
  }

  int _calculateDayCount() {
    final String startDateStr = _destData['startDate'] ?? '';
    final String endDateStr = _destData['endDate'] ?? '';

    if (startDateStr.isEmpty || endDateStr.isEmpty) return 0;

    try {
      final start = DateTime.parse(startDateStr);
      final end = DateTime.parse(endDateStr);
      return end.difference(start).inDays + 1;
    } catch (e) {
      return 0;
    }
  }

  void _initializeItinerary() {
    if (_destData['itinerary'] == null || (_destData['itinerary'] as List).isEmpty) {
      final itinerary = <Map<String, dynamic>>[];
      for (int i = 0; i < _dayCount; i++) {
        itinerary.add({
          'title': 'Day ${i + 1}',
          'notes': '',
          'activities': <Map<String, dynamic>>[],
        });
      }
      _destData['itinerary'] = itinerary;
    }
  }

  @override
  void dispose() {
    _mainTabController.dispose();
    _weekTabController.dispose();
    super.dispose();
  }

  Future<void> _saveChanges() async {
    setState(() => _saving = true);
    try {
      final tripRef = FirebaseFirestore.instance.doc(widget.tripRef);
      final snapshot = await tripRef.get();
      final tripData = snapshot.data() ?? {};
      final waypoints = List<Map<String, dynamic>>.from(
        (tripData['waypoints'] as List<dynamic>? ?? []).map(
          (w) => Map<String, dynamic>.from(w as Map),
        ),
      );

      if (widget.destinationIndex >= 0 &&
          widget.destinationIndex < waypoints.length) {
        waypoints[widget.destinationIndex] = _destData;
      }

      await tripRef.update({'waypoints': waypoints});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✓ Destination plan saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final destName = _destData['name'] ?? 'Unknown Destination';

    return Scaffold(
      appBar: AppBar(
        title: Text(destName),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.black87,
        actions: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child:
                _saving
                    ? const Center(child: CircularProgressIndicator())
                    : GradientButton(
                      onPressed: _saveChanges,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.save, size: 16),
                          SizedBox(width: 6),
                          Text('Save'),
                        ],
                      ),
                    ),
          ),
        ],
        bottom: TabBar(
          controller: _mainTabController,
          labelColor: Colors.black87,
          unselectedLabelColor: Colors.grey,
          indicatorColor: const Color(0xFF00695C),
          tabs: const [
            Tab(icon: Icon(Icons.calendar_today), text: 'Dates'),
            Tab(icon: Icon(Icons.hotel), text: 'Accommodations'),
            Tab(icon: Icon(Icons.schedule), text: 'Itinerary'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _mainTabController,
        children: [
          _buildDateRangeTab(),
          _buildAccommodationsTab(),
          _buildItineraryMainTab(),
        ],
      ),
    );
  }

  // ============ DATES TAB ============
  Widget _buildDateRangeTab() {
    final String startDateStr = _destData['startDate'] ?? '';
    final String endDateStr = _destData['endDate'] ?? '';

    int durationDays = 0;
    if (startDateStr.isNotEmpty && endDateStr.isNotEmpty) {
      try {
        final start = DateTime.parse(startDateStr);
        final end = DateTime.parse(endDateStr);
        durationDays = end.difference(start).inDays + 1;
      } catch (e) {
        // Invalid date format
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your Stay Duration',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Select your arrival and departure dates',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 32),
          GlassCard(
            padding: const EdgeInsets.all(20),
            borderRadius: 16,
            child: Column(
              children: [
                GradientButton(
                  onPressed: _selectStartDate,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.today, size: 20),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Arrival',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            startDateStr.isEmpty
                                ? 'Tap to select'
                                : _formatDisplayDate(startDateStr),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Icon(
                        Icons.arrow_downward,
                        color: const Color(0xFF00695C).withOpacity(0.5),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 16),
                GradientButton(
                  onPressed: _selectEndDate,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.calendar_today, size: 20),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Departure',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            endDateStr.isEmpty
                                ? 'Tap to select'
                                : _formatDisplayDate(endDateStr),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (durationDays > 0) ...[
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00695C), Color(0xFF004D40)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(
                    'Trip Duration',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Colors.white70,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$durationDays day${durationDays > 1 ? 's' : ''}',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ============ ACCOMMODATIONS TAB ============
  Widget _buildAccommodationsTab() {
    List<Map<String, dynamic>> accommodations = List<Map<String, dynamic>>.from(
      (_destData['accommodations'] as List<dynamic>? ?? []).map(
        (a) => Map<String, dynamic>.from(a as Map),
      ),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Accommodations',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              GradientButton(
                onPressed: () => _showAIAssistant('accommodations'),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome, size: 16),
                    SizedBox(width: 6),
                    Text('AI Suggest'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...accommodations.asMap().entries.map((entry) {
            final idx = entry.key;
            final acc = entry.value;
            return _buildAccommodationCard(idx, acc, accommodations);
          }),
          const SizedBox(height: 16),
          GradientButton(
            onPressed: () => _addAccommodation(accommodations),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 18),
                SizedBox(width: 6),
                Text('Add Accommodation'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccommodationCard(
    int index,
    Map<String, dynamic> accommodation,
    List<Map<String, dynamic>> accommodations,
  ) {
    return GlassCard(
      padding: const EdgeInsets.all(12),
      borderRadius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: TextField(
                  textDirection: TextDirection.ltr,
                  controller: TextEditingController(
                    text: accommodation['name'] ?? '',
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Hotel Name',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    setState(() {
                      accommodation['name'] = v;
                      accommodations[index] = accommodation;
                      _destData['accommodations'] = accommodations;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () {
                  setState(() {
                    accommodations.removeAt(index);
                    _destData['accommodations'] = accommodations;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            textDirection: TextDirection.ltr,
            controller: TextEditingController(
              text: accommodation['address'] ?? '',
            ),
            decoration: const InputDecoration(
              labelText: 'Address',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              setState(() {
                accommodation['address'] = v;
                accommodations[index] = accommodation;
                _destData['accommodations'] = accommodations;
              });
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  textDirection: TextDirection.ltr,
                  controller: TextEditingController(
                    text: accommodation['price']?.toString() ?? '',
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Price per Night',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    setState(() {
                      accommodation['price'] = double.tryParse(v) ?? 0;
                      accommodations[index] = accommodation;
                      _destData['accommodations'] = accommodations;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  textDirection: TextDirection.ltr,
                  controller: TextEditingController(
                    text: accommodation['rating']?.toString() ?? '',
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Rating',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    setState(() {
                      accommodation['rating'] = double.tryParse(v) ?? 0;
                      accommodations[index] = accommodation;
                      _destData['accommodations'] = accommodations;
                    });
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _addAccommodation(List<Map<String, dynamic>> accommodations) {
    setState(() {
      accommodations.add({'name': '', 'address': '', 'price': 0, 'rating': 0});
      _destData['accommodations'] = accommodations;
    });
  }

  // ============ ITINERARY MAIN TAB (WITH WEEK TABS) ============
  Widget _buildItineraryMainTab() {
    if (_dayCount == 0) {
      return Center(
        child: Text(
          'Set dates first to plan your itinerary',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Colors.grey),
        ),
      );
    }

    return Column(
      children: [
        // Week tabbar
        TabBar(
          controller: _weekTabController,
          labelColor: Colors.black87,
          unselectedLabelColor: Colors.grey,
          indicatorColor: const Color(0xFF00695C),
          isScrollable: true,
          tabs: List.generate(
            _weekCount,
            (i) {
              final startDay = i * 7 + 1;
              final endDay = ((i + 1) * 7).clamp(0, _dayCount);
              return Tab(text: 'Week ${i + 1} (Days $startDay-$endDay)');
            },
          ),
        ),
        // Week tabview
        Expanded(
          child: TabBarView(
            controller: _weekTabController,
            children: List.generate(
              _weekCount,
              (weekIndex) => _buildWeekView(weekIndex),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWeekView(int weekIndex) {
    final startDayIndex = weekIndex * 7;
    final endDayIndex = ((weekIndex + 1) * 7).clamp(0, _dayCount);
    final daysInWeek = endDayIndex - startDayIndex;

    List<Map<String, dynamic>> itinerary = List<Map<String, dynamic>>.from(
      (_destData['itinerary'] as List<dynamic>? ?? []).map(
        (d) => Map<String, dynamic>.from(d as Map),
      ),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: List.generate(
          daysInWeek,
          (localDayIndex) {
            final globalDayIndex = startDayIndex + localDayIndex;
            return Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: _buildDayCard(globalDayIndex, itinerary),
            );
          },
        ),
      ),
    );
  }

  Widget _buildDayCard(int dayIndex, List<Map<String, dynamic>> itinerary) {
    // Ensure day exists
    while (itinerary.length <= dayIndex) {
      itinerary.add({
        'title': 'Day ${itinerary.length + 1}',
        'notes': '',
        'activities': <Map<String, dynamic>>[],
      });
    }

    _destData['itinerary'] = itinerary;
    final dayData = itinerary[dayIndex];
    List<Map<String, dynamic>> activities = List<Map<String, dynamic>>.from(
      (dayData['activities'] as List<dynamic>? ?? []).map(
        (a) => Map<String, dynamic>.from(a as Map),
      ),
    );

    return GlassCard(
      padding: const EdgeInsets.all(16),
      borderRadius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Day title
          TextField(
            textDirection: TextDirection.ltr,
            controller: TextEditingController(text: dayData['title'] ?? ''),
            decoration: const InputDecoration(
              hintText: 'Day title',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              setState(() {
                dayData['title'] = v;
                itinerary[dayIndex] = dayData;
                _destData['itinerary'] = itinerary;
              });
            },
          ),
          const SizedBox(height: 12),
          // Day notes
          TextField(
            textDirection: TextDirection.ltr,
            controller: TextEditingController(text: dayData['notes'] ?? ''),
            decoration: const InputDecoration(
              hintText: 'Day notes or overview',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
            onChanged: (v) {
              setState(() {
                dayData['notes'] = v;
                itinerary[dayIndex] = dayData;
                _destData['itinerary'] = itinerary;
              });
            },
          ),
          const SizedBox(height: 20),
          // Activities list
          if (activities.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Activities',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                ...activities.asMap().entries.map((entry) {
                  final actIdx = entry.key;
                  final activity = entry.value;
                  return _buildActivityCard(
                    activity,
                    actIdx,
                    activities,
                    dayData,
                    itinerary,
                    dayIndex,
                  );
                }),
                const SizedBox(height: 12),
              ],
            ),
          // Add activity button
          GradientButton(
            onPressed: () => _showActivityDialog(
              activities,
              dayData,
              itinerary,
              dayIndex,
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, size: 18),
                SizedBox(width: 8),
                Text('Add Activity'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityCard(
    Map<String, dynamic> activity,
    int activityIndex,
    List<Map<String, dynamic>> activities,
    Map<String, dynamic> dayData,
    List<Map<String, dynamic>> itinerary,
    int dayIndex,
  ) {
    final category = activity['category'] as String? ?? 'Activity';
    final color = travelCategories[category] ?? Colors.teal;

    return GestureDetector(
      onTap: () => _showActivityDialog(
        activities,
        dayData,
        itinerary,
        dayIndex,
        activity,
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          border: Border.all(color: color, width: 1.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 60,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    activity['title'] ?? 'Untitled',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${activity['time'] ?? '--:--'} • ${activity['location'] ?? 'No location'}',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Colors.grey),
                  ),
                  if ((activity['notes'] ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        activity['notes'],
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withOpacity(0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                category,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showActivityDialog(
    List<Map<String, dynamic>> activities,
    Map<String, dynamic> dayData,
    List<Map<String, dynamic>> itinerary,
    int dayIndex, [
    Map<String, dynamic>? existingActivity,
  ]) {
    final isEdit = existingActivity != null;
    final activity = isEdit ? Map<String, dynamic>.from(existingActivity) : {};

    final titleCtrl = TextEditingController(text: activity['title'] ?? '');
    final timeCtrl = TextEditingController(text: activity['time'] ?? '');
    final locationCtrl = TextEditingController(
      text: activity['location'] ?? '',
    );
    final notesCtrl = TextEditingController(text: activity['notes'] ?? '');
    String selectedCategory = activity['category'] ?? 'Hiking';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? 'Edit Activity' : 'Add Activity'),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title
                TextField(
                  textDirection: TextDirection.ltr,
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Activity Title',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                // Time picker with button
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        textDirection: TextDirection.ltr,
                        controller: timeCtrl,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: 'Time (HH:MM)',
                          border: OutlineInputBorder(),
                          hintText: '09:00',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GradientButton(
                      onPressed: () async {
                        final timeOfDay = await showTimePicker(
                          context: ctx,
                          initialTime: TimeOfDay.now(),
                        );
                        if (timeOfDay != null) {
                          final formattedTime =
                              '${timeOfDay.hour.toString().padLeft(2, '0')}:${timeOfDay.minute.toString().padLeft(2, '0')}';
                          setState(() {
                            timeCtrl.text = formattedTime;
                          });
                        }
                      },
                      child: const Icon(Icons.access_time),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Location
                TextField(
                  textDirection: TextDirection.ltr,
                  controller: locationCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Location',
                    border: OutlineInputBorder(),
                    suffixIcon: Icon(Icons.location_on),
                  ),
                ),
                const SizedBox(height: 12),
                // Notes
                TextField(
                  textDirection: TextDirection.ltr,
                  controller: notesCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                // Category dropdown
                DropdownButtonFormField<String>(
                  initialValue: selectedCategory,
                  decoration: const InputDecoration(
                    labelText: 'Category',
                    border: OutlineInputBorder(),
                  ),
                  items: travelCategories.keys.map((cat) {
                    return DropdownMenuItem(
                      value: cat,
                      child: Row(
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: travelCategories[cat],
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(cat),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() {
                      selectedCategory = value ?? 'Hiking';
                    });
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          if (isEdit)
            TextButton(
              onPressed: () {
                setState(() {
                  final idx = activities.indexOf(existingActivity);
                  if (idx >= 0) {
                    activities.removeAt(idx);
                  }
                  dayData['activities'] = activities;
                  itinerary[dayIndex] = dayData;
                  _destData['itinerary'] = itinerary;
                });
                Navigator.pop(ctx);
              },
              child: const Text(
                'Delete',
                style: TextStyle(color: Colors.red),
              ),
            ),
          TextButton(
            onPressed: () {
              setState(() {
                final newActivity = {
                  'title': titleCtrl.text,
                  'time': timeCtrl.text,
                  'location': locationCtrl.text,
                  'notes': notesCtrl.text,
                  'category': selectedCategory,
                };

                if (isEdit) {
                  final idx = activities.indexOf(existingActivity);
                  if (idx >= 0) {
                    activities[idx] = newActivity;
                  }
                } else {
                  activities.add(newActivity);
                }

                dayData['activities'] = activities;
                itinerary[dayIndex] = dayData;
                _destData['itinerary'] = itinerary;
              });
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ============ HELPER METHODS ============
  String _formatDisplayDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return '${date.month}/${date.day}/${date.year}';
    } catch (e) {
      return dateStr;
    }
  }

  Future<void> _selectStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null) {
      setState(() {
        _destData['startDate'] = picked.toIso8601String().split('T')[0];
        _dayCount = _calculateDayCount();
        _weekCount = (_dayCount / 7).ceil();
        _weekTabController.dispose();
        _weekTabController = TabController(
          length: _weekCount > 0 ? _weekCount : 1,
          vsync: this,
        );
        _initializeItinerary();
      });
    }
  }

  Future<void> _selectEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null) {
      setState(() {
        _destData['endDate'] = picked.toIso8601String().split('T')[0];
        _dayCount = _calculateDayCount();
        _weekCount = (_dayCount / 7).ceil();
        _weekTabController.dispose();
        _weekTabController = TabController(
          length: _weekCount > 0 ? _weekCount : 1,
          vsync: this,
        );
        _initializeItinerary();
      });
    }
  }

  void _showAIAssistant(String context) {
    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(content: Text('AI Assistant for $context coming soon!')),
    );
  }
}
