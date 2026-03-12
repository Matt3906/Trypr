// ignore_for_file: unused_element, unused_field, unused_local_variable

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/widgets/modern_widgets.dart';

/// Destination Detail Screen: Plan accommodations, daily itinerary, activities for a specific location.
class DestinationDetailScreen extends StatefulWidget {
  final String tripId;
  final int destinationIndex;
  final Map<String, dynamic> destination;
  final String tripRef; // Path to the trip document for saving
  final String? userId; // Current user ID for reference

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
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late Map<String, dynamic> _destData;
  bool _saving = false;
  late int _dayTabCount; // Dynamic tab count based on duration

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    _destData = Map<String, dynamic>.from(widget.destination);
    _dayTabCount = _calculateDayCount();
    // If we have days, add 1 for the itinerary tab itself, otherwise just Dates + Accommodations
    _tabController = TabController(
      length: _dayTabCount > 0 ? 3 + _dayTabCount : 2,
      vsync: this,
    );
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

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<Tab> _generateDayTabs() {
    List<Tab> tabs = [];
    for (int i = 0; i < _dayTabCount; i++) {
      tabs.add(Tab(text: 'Day ${i + 1}'));
    }
    return tabs;
  }

  List<Widget> _generateDayViews() {
    List<Widget> views = [];
    for (int i = 0; i < _dayTabCount; i++) {
      views.add(_buildDayScheduleView(i));
    }
    return views;
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
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(content: Text('Destination plan saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final destName = _destData['name'] ?? 'Unknown Destination';
    final lat = _destData['lat'] as num?;
    final lon = _destData['lon'] as num?;

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
          controller: _tabController,
          labelColor: Colors.black87,
          unselectedLabelColor: Colors.grey,
          indicatorColor: const Color(0xFF00695C),
          isScrollable: _dayTabCount > 2,
          tabs: [
            const Tab(icon: Icon(Icons.calendar_today), text: 'Dates'),
            const Tab(icon: Icon(Icons.hotel), text: 'Accommodations'),
            if (_dayTabCount > 0) ...[
              const Tab(icon: Icon(Icons.schedule), text: 'Itinerary'),
              ..._generateDayTabs(),
            ],
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDateRangeTab(),
          _buildAccommodationsTab(),
          if (_dayTabCount > 0) ...[
            _buildItineraryOverviewTab(),
            ..._generateDayViews(),
          ],
        ],
      ),
    );
  }

  // ============ ITINERARY OVERVIEW TAB ============
  Widget _buildItineraryOverviewTab() {
    List<Map<String, dynamic>> allDays = List<Map<String, dynamic>>.from(
      (_destData['itinerary'] as List<dynamic>? ?? []).map(
        (d) => Map<String, dynamic>.from(d as Map),
      ),
    );

    // Ensure we have enough days
    while (allDays.length < _dayTabCount) {
      allDays.add({
        'title': 'Day ${allDays.length + 1}',
        'notes': '',
        'activities': [],
      });
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Trip Itinerary Overview',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Text(
            'You have $_dayTabCount day${_dayTabCount > 1 ? 's' : ''} planned. Click on each day tab to edit.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          ...allDays.asMap().entries.map((entry) {
            final dayIdx = entry.key;
            final dayData = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GlassCard(
                padding: const EdgeInsets.all(14),
                borderRadius: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Day ${dayIdx + 1}',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              width: 200,
                              child: Text(
                                dayData['title'] ?? 'Unnamed',
                                style: Theme.of(context).textTheme.bodyMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00695C).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${(dayData['activities'] as List<dynamic>? ?? []).length} activities',
                            style: Theme.of(
                              context,
                            ).textTheme.labelSmall?.copyWith(
                              color: const Color(0xFF00695C),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if ((dayData['notes'] as String? ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        dayData['notes'] as String,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ============ DAY SCHEDULE TAB (Google Calendar Style) ============
  Widget _buildDayScheduleView(int dayIndex) {
    List<Map<String, dynamic>> allDays = List<Map<String, dynamic>>.from(
      (_destData['itinerary'] as List<dynamic>? ?? []).map(
        (d) => Map<String, dynamic>.from(d as Map),
      ),
    );

    // Ensure we have enough days
    while (allDays.length <= dayIndex) {
      allDays.add({
        'title': 'Day ${allDays.length + 1}',
        'notes': '',
        'activities': [],
      });
    }

    final dayData = allDays[dayIndex];
    List<Map<String, dynamic>> activities = List<Map<String, dynamic>>.from(
      (dayData['activities'] as List<dynamic>? ?? []).map(
        (a) => Map<String, dynamic>.from(a as Map),
      ),
    );

    // Sort activities by time
    activities.sort((a, b) {
      final timeA = a['time'] ?? '00:00';
      final timeB = b['time'] ?? '00:00';
      return timeA.compareTo(timeB);
    });

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Day Header with AI button
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dayData['title'] ?? 'Day ${dayIndex + 1}',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          dayData['notes'] ?? 'No overview set',
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                          maxLines: 2,
                        ),
                      ],
                    ),
                    Column(
                      children: [
                        GradientButton(
                          onPressed: () => _showAIAssistant('itinerary'),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.auto_awesome, size: 16),
                              SizedBox(width: 6),
                              Text('AI Plan'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Day title/notes edit row
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(
                          text: dayData['title'] ?? '',
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Day title',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        onChanged: (v) {
                          setState(() {
                            dayData['title'] = v;
                            allDays[dayIndex] = dayData;
                            _destData['itinerary'] = allDays;
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: TextEditingController(
                    text: dayData['notes'] ?? '',
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Overview or notes for this day',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  maxLines: 2,
                  onChanged: (v) {
                    setState(() {
                      dayData['notes'] = v;
                      allDays[dayIndex] = dayData;
                      _destData['itinerary'] = allDays;
                    });
                  },
                ),
              ],
            ),
          ),
          // Timeline Activities
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Schedule',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    GradientButton(
                      onPressed:
                          () => _addActivityToDay(
                            activities,
                            dayData,
                            allDays,
                            dayIndex,
                          ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add, size: 16),
                          SizedBox(width: 4),
                          Text('Add Activity'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Calendar-like activity timeline
          if (activities.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: Center(
                child: Text(
                  'No activities scheduled. Tap "Add Activity" to get started!',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children:
                    activities.asMap().entries.map((entry) {
                      final actIdx = entry.key;
                      final act = entry.value;
                      return _buildCalendarActivityBlock(
                        actIdx,
                        act,
                        activities,
                        dayData,
                        allDays,
                        dayIndex,
                      );
                    }).toList(),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildCalendarActivityBlock(
    int actIdx,
    Map<String, dynamic> activity,
    List<Map<String, dynamic>> activities,
    Map<String, dynamic> dayData,
    List<Map<String, dynamic>> allDays,
    int dayIndex,
  ) {
    final time = activity['time'] ?? 'TBD';
    final title = activity['title'] ?? 'Unnamed Activity';
    final description = activity['description'] ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        borderRadius: 12,
        child: InkWell(
          onTap:
              () => _editActivity(
                actIdx,
                activity,
                activities,
                dayData,
                allDays,
                dayIndex,
              ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00695C).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          time,
                          style: Theme.of(
                            context,
                          ).textTheme.labelMedium?.copyWith(
                            color: const Color(0xFF00695C),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        SizedBox(
                          width: 220,
                          child: Text(
                            description,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.red,
                      size: 20,
                    ),
                    onPressed: () {
                      setState(() {
                        activities.removeAt(actIdx);
                        dayData['activities'] = activities;
                        allDays[dayIndex] = dayData;
                        _destData['itinerary'] = allDays;
                      });
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _editActivity(
    int actIdx,
    Map<String, dynamic> activity,
    List<Map<String, dynamic>> activities,
    Map<String, dynamic> dayData,
    List<Map<String, dynamic>> allDays,
    int dayIndex,
  ) {
    final titleCtrl = TextEditingController(text: activity['title'] ?? '');
    final timeCtrl = TextEditingController(text: activity['time'] ?? '');
    final descCtrl = TextEditingController(text: activity['description'] ?? '');

    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Edit Activity'),
            content: SingleChildScrollView(
              child: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Activity Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: timeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Time (e.g., 09:00 AM - 01:00 PM)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 3,
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
              TextButton(
                onPressed: () {
                  setState(() {
                    activity['title'] = titleCtrl.text;
                    activity['time'] = timeCtrl.text;
                    activity['description'] = descCtrl.text;
                    activities[actIdx] = activity;
                    dayData['activities'] = activities;
                    allDays[dayIndex] = dayData;
                    _destData['itinerary'] = allDays;
                  });
                  Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          ),
    );
  }

  void _addActivityToDay(
    List<Map<String, dynamic>> activities,
    Map<String, dynamic> dayData,
    List<Map<String, dynamic>> allDays,
    int dayIndex,
  ) {
    setState(() {
      activities.add({'title': 'New Activity', 'time': '', 'description': ''});
      dayData['activities'] = activities;
      allDays[dayIndex] = dayData;
      _destData['itinerary'] = allDays;
    });
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
    final nameCtrl = TextEditingController(text: accommodation['name'] ?? '');
    final addressCtrl = TextEditingController(
      text: accommodation['address'] ?? '',
    );
    final priceCtrl = TextEditingController(
      text: accommodation['price']?.toString() ?? '',
    );
    final notesCtrl = TextEditingController(text: accommodation['notes'] ?? '');

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
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Hotel/Accommodation Name',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    accommodation['name'] = v;
                    _destData['accommodations'] = accommodations;
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
            controller: addressCtrl,
            decoration: const InputDecoration(
              labelText: 'Address',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              accommodation['address'] = v;
              _destData['accommodations'] = accommodations;
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: priceCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Price per Night',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    accommodation['price'] = double.tryParse(v) ?? 0;
                    _destData['accommodations'] = accommodations;
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: TextEditingController(
                    text: accommodation['checkIn'] ?? '',
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Check-in Date',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    accommodation['checkIn'] = v;
                    _destData['accommodations'] = accommodations;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: notesCtrl,
            decoration: const InputDecoration(
              labelText: 'Notes (amenities, booking ref, etc)',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
            onChanged: (v) {
              accommodation['notes'] = v;
              _destData['accommodations'] = accommodations;
            },
          ),
        ],
      ),
    );
  }

  void _addAccommodation(List<Map<String, dynamic>> accommodations) {
    setState(() {
      accommodations.add({
        'name': '',
        'address': '',
        'price': 0,
        'checkIn': '',
        'notes': '',
      });
      _destData['accommodations'] = accommodations;
    });
  }

  // ============ DATE RANGE TAB ============
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
          // Simplified 2-click date range selector
          GlassCard(
            padding: const EdgeInsets.all(20),
            borderRadius: 16,
            child: Column(
              children: [
                // Arrival Date Button
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
                // Divider with arrow
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
                // Departure Date Button
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
          // Duration Summary
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
          // Helper text
          if (startDateStr.isEmpty || endDateStr.isEmpty) ...[
            const SizedBox(height: 24),
            GlassCard(
              padding: const EdgeInsets.all(12),
              borderRadius: 12,
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 20, color: Colors.blue),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Set both dates to create daily tabs for your itinerary.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.blue),
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

  String _formatDisplayDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return '${date.month}/${date.day}/${date.year}';
    } catch (e) {
      return dateStr;
    }
  }

  Future<void> _selectStartDate() async {
    final String currentStr = _destData['startDate'] ?? '';
    DateTime initialDate = DateTime.now();
    if (currentStr.isNotEmpty) {
      try {
        initialDate = DateTime.parse(currentStr);
      } catch (e) {
        // Use current date
      }
    }

    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );

    if (picked != null) {
      setState(() {
        _destData['startDate'] = picked.toIso8601String().split('T')[0];
        // Initialize itinerary days if not present
        _updateItineraryDays();
        _updateTabController();
      });
    }
  }

  Future<void> _selectEndDate() async {
    final String currentStr = _destData['endDate'] ?? '';
    DateTime initialDate = DateTime.now();
    if (currentStr.isNotEmpty) {
      try {
        initialDate = DateTime.parse(currentStr);
      } catch (e) {
        // Use current date
      }
    }

    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );

    if (picked != null) {
      setState(() {
        _destData['endDate'] = picked.toIso8601String().split('T')[0];
        // Initialize itinerary days if not present
        _updateItineraryDays();
        _updateTabController();
      });
    }
  }

  void _updateTabController() {
    final newDayCount = _calculateDayCount();
    if (newDayCount != _dayTabCount) {
      _dayTabCount = newDayCount;
      _tabController.dispose();
      _tabController = TabController(
        length: _dayTabCount > 0 ? 3 + _dayTabCount : 2,
        vsync: this,
      );
    }
  }

  void _updateItineraryDays() {
    final newDayCount = _calculateDayCount();
    List<Map<String, dynamic>> itinerary = List<Map<String, dynamic>>.from(
      (_destData['itinerary'] as List<dynamic>? ?? []).map(
        (d) => Map<String, dynamic>.from(d as Map),
      ),
    );

    // Add missing days
    while (itinerary.length < newDayCount) {
      itinerary.add({
        'title': 'Day ${itinerary.length + 1}',
        'notes': '',
        'activities': [],
      });
    }

    _destData['itinerary'] = itinerary;
  }

  // ============ AI ASSISTANT TAB ============
  Widget _buildAIAssistantTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AI Trip Planner Assistant',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            'Get AI-powered recommendations for accommodations, restaurants, activities, and attractions in ${_destData['name']}.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          _buildAICard(
            icon: Icons.hotel,
            title: 'Find Accommodations',
            subtitle: 'Get hotel and lodging recommendations',
            onTap: () => _showAIAssistant('accommodations'),
          ),
          const SizedBox(height: 12),
          _buildAICard(
            icon: Icons.restaurant,
            title: 'Find Restaurants',
            subtitle: 'Discover dining options & cuisines',
            onTap: () => _showAIAssistant('restaurants'),
          ),
          const SizedBox(height: 12),
          _buildAICard(
            icon: Icons.place,
            title: 'Find Attractions',
            subtitle: 'Explore must-see places & activities',
            onTap: () => _showAIAssistant('attractions'),
          ),
          const SizedBox(height: 12),
          _buildAICard(
            icon: Icons.schedule,
            title: 'Generate Itinerary',
            subtitle: 'AI-powered daily schedule',
            onTap: () => _showAIAssistant('itinerary'),
          ),
          const SizedBox(height: 12),
          _buildAICard(
            icon: Icons.chat,
            title: 'Custom Questions',
            subtitle: 'Ask anything about your destination',
            onTap: () => _showAIAssistant('custom'),
          ),
        ],
      ),
    );
  }

  Widget _buildAICard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      borderRadius: 12,
      child: InkWell(
        onTap: onTap,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF00695C).withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: const Color(0xFF00695C), size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, size: 16),
          ],
        ),
      ),
    );
  }

  void _showAIAssistant(String mode) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder:
          (ctx) => AIAssistantSheet(
            destination: _destData['name'] ?? 'Unknown',
            mode: mode,
            onSelectResult: (result) {
              _integrateAIResult(mode, result);
            },
          ),
    );
  }

  void _integrateAIResult(String mode, Map<String, dynamic> result) {
    setState(() {
      if (mode == 'accommodations') {
        List<Map<String, dynamic>> accs = List<Map<String, dynamic>>.from(
          (_destData['accommodations'] as List<dynamic>? ?? []).map(
            (a) => Map<String, dynamic>.from(a as Map),
          ),
        );
        accs.add(result);
        _destData['accommodations'] = accs;
      } else if (mode == 'restaurants') {
        List<Map<String, dynamic>> things = List<Map<String, dynamic>>.from(
          (_destData['things_to_do'] as List<dynamic>? ?? []).map(
            (a) => Map<String, dynamic>.from(a as Map),
          ),
        );
        things.add({...result, 'category': 'Restaurant'});
        _destData['things_to_do'] = things;
      } else if (mode == 'attractions') {
        List<Map<String, dynamic>> things = List<Map<String, dynamic>>.from(
          (_destData['things_to_do'] as List<dynamic>? ?? []).map(
            (a) => Map<String, dynamic>.from(a as Map),
          ),
        );
        things.add({...result, 'category': 'Attraction'});
        _destData['things_to_do'] = things;
      }
    });
  }
}

/// AI Assistant Sheet for generating recommendations
class AIAssistantSheet extends StatefulWidget {
  final String destination;
  final String mode;
  final Function(Map<String, dynamic>) onSelectResult;

  const AIAssistantSheet({
    super.key,
    required this.destination,
    required this.mode,
    required this.onSelectResult,
  });

  @override
  State<AIAssistantSheet> createState() => _AIAssistantSheetState();
}

class _AIAssistantSheetState extends State<AIAssistantSheet> {
  final _queryCtrl = TextEditingController();
  bool _loading = false;
  List<Map<String, dynamic>> _results = [];
  String _errorMsg = '';

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _generateRecommendations() async {
    setState(() {
      _loading = true;
      _errorMsg = '';
      _results = [];
    });

    try {
      // TODO: Integrate with your backend AI service (e.g., OpenAI, Gemini, etc.)
      // For now, mock data with a delay
      await Future.delayed(const Duration(seconds: 1));

      setState(() {
        _results = [
          {
            'name': 'Luxe Hotel ${widget.destination}',
            'description': 'Modern luxury hotel with excellent reviews',
            'price': 150,
            'rating': 4.8,
          },
          {
            'name': 'Budget Hostel ${widget.destination}',
            'description': 'Social and affordable stay',
            'price': 45,
            'rating': 4.2,
          },
          {
            'name': 'Boutique Inn ${widget.destination}',
            'description': 'Charming local experience',
            'price': 95,
            'rating': 4.6,
          },
        ];
      });
    } catch (e) {
      setState(() {
        _errorMsg = 'Failed to generate recommendations: $e';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      maxChildSize: 0.9,
      builder:
          (ctx, scrollController) => Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
            ),
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'AI Recommendations',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Ask AI for ${widget.mode} in ${widget.destination}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _queryCtrl,
                    decoration: InputDecoration(
                      hintText: _getPlaceholder(widget.mode),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.send),
                        onPressed: _generateRecommendations,
                      ),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 16),
                  if (_loading)
                    const Center(child: CircularProgressIndicator())
                  else if (_errorMsg.isNotEmpty)
                    Text(_errorMsg, style: const TextStyle(color: Colors.red))
                  else if (_results.isEmpty)
                    Text(
                      'Submit a query to get recommendations',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else
                    Column(
                      children:
                          _results.map((result) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Card(
                                child: ListTile(
                                  title: Text(result['name'] ?? 'Unknown'),
                                  subtitle: Text(result['description'] ?? ''),
                                  trailing: ElevatedButton(
                                    onPressed: () {
                                      widget.onSelectResult(result);
                                      Navigator.pop(ctx);
                                    },
                                    child: const Text('Add'),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                    ),
                ],
              ),
            ),
          ),
    );
  }

  String _getPlaceholder(String mode) {
    switch (mode) {
      case 'accommodations':
        return 'E.g., Luxury 5-star hotel near city center, beach access...';
      case 'restaurants':
        return 'E.g., Best seafood restaurants, local cuisine, vegan options...';
      case 'attractions':
        return 'E.g., Top museums, hiking trails, historical sites...';
      case 'itinerary':
        return 'E.g., 3-day itinerary for budget travelers, adventure activities...';
      default:
        return 'Ask anything about this destination...';
    }
  }
}
