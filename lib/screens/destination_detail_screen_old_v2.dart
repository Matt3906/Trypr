import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/widgets/modern_widgets.dart';

/// Destination Detail Screen V2: Complete redesign with Google Calendar-style itinerary
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
  late TabController _dayTabController;
  late Map<String, dynamic> _destData;
  bool _saving = false;
  late int _dayCount;

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    _destData = Map<String, dynamic>.from(widget.destination);
    _dayCount = _calculateDayCount();
    _mainTabController = TabController(length: 3, vsync: this);
    _dayTabController = TabController(
      length: _dayCount > 0 ? _dayCount : 1,
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
    _mainTabController.dispose();
    _dayTabController.dispose();
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
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

  // ============ ITINERARY MAIN TAB (WITH SUB-TABS) ============
  Widget _buildItineraryMainTab() {
    if (_dayCount == 0) {
      return Center(
        child: Text(
          'Set dates first to plan your itinerary',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
        ),
      );
    }

    return Column(
      children: [
        // Sub-tabbar for days
        TabBar(
          controller: _dayTabController,
          labelColor: Colors.black87,
          unselectedLabelColor: Colors.grey,
          indicatorColor: const Color(0xFF00695C),
          isScrollable: true,
          tabs: List.generate(_dayCount, (i) => Tab(text: 'Day ${i + 1}')),
        ),
        // Sub-tabview for day schedules
        Expanded(
          child: TabBarView(
            controller: _dayTabController,
            children: List.generate(
              _dayCount,
              (dayIndex) => _buildGoogleCalendarView(dayIndex),
            ),
          ),
        ),
      ],
    );
  }

  // ============ GOOGLE CALENDAR STYLE DAY VIEW ============
  Widget _buildGoogleCalendarView(int dayIndex) {
    List<Map<String, dynamic>> itinerary = List<Map<String, dynamic>>.from(
      (_destData['itinerary'] as List<dynamic>? ?? []).map(
        (d) => Map<String, dynamic>.from(d as Map),
      ),
    );

    // Ensure day exists
    while (itinerary.length <= dayIndex) {
      itinerary.add({
        'title': 'Day ${itinerary.length + 1}',
        'notes': '',
        'activities': [],
      });
    }

    final dayData = itinerary[dayIndex];
    List<Map<String, dynamic>> activities = List<Map<String, dynamic>>.from(
      (dayData['activities'] as List<dynamic>? ?? []).map(
        (a) => Map<String, dynamic>.from(a as Map),
      ),
    );

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Day title and notes
            TextField(
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
            TextField(
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
            // Calendar grid
            _buildCalendarGrid(activities, dayData, itinerary, dayIndex),
            const SizedBox(height: 20),
            // Add activity button
            GradientButton(
              onPressed:
                  () => _showActivityDialog(
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
      ),
    );
  }

  Widget _buildCalendarGrid(
    List<Map<String, dynamic>> activities,
    Map<String, dynamic> dayData,
    List<Map<String, dynamic>> itinerary,
    int dayIndex,
  ) {
    final hours = List.generate(24, (i) => i);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children:
            hours.map((hour) {
              final hourStr = '${hour.toString().padLeft(2, '0')}:00';
              final hourActivities =
                  activities.where((a) {
                    final time = a['time'] as String? ?? '';
                    if (time.isEmpty) return false;
                    return time.startsWith(hour.toString().padLeft(2, '0'));
                  }).toList();

              return Container(
                height: 60,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                child: Row(
                  children: [
                    // Hour label
                    SizedBox(
                      width: 60,
                      child: Center(
                        child: Text(
                          hourStr,
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(color: Colors.grey),
                        ),
                      ),
                    ),
                    // Activities for this hour
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child:
                            hourActivities.isEmpty
                                ? const SizedBox()
                                : Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children:
                                      hourActivities.map((activity) {
                                        return _buildActivityChip(
                                          activity,
                                          activities,
                                          dayData,
                                          itinerary,
                                          dayIndex,
                                        );
                                      }).toList(),
                                ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
      ),
    );
  }

  Widget _buildActivityChip(
    Map<String, dynamic> activity,
    List<Map<String, dynamic>> activities,
    Map<String, dynamic> dayData,
    List<Map<String, dynamic>> itinerary,
    int dayIndex,
  ) {
    final categoryColors = {
      'Work': Colors.blue,
      'Meeting': Colors.purple,
      'Travel': Colors.orange,
      'Meal': Colors.red,
      'Activity': Colors.green,
      'Rest': Colors.indigo,
    };

    final category = activity['category'] as String? ?? 'Activity';
    final color = categoryColors[category] ?? Colors.teal;

    return GestureDetector(
      onTap:
          () => _showActivityDialog(
            activities,
            dayData,
            itinerary,
            dayIndex,
            activity,
          ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.8),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              activity['title'] ?? 'Untitled',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              activity['time'] ?? '',
              style: const TextStyle(color: Colors.white70, fontSize: 9),
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
    String selectedCategory = activity['category'] ?? 'Activity';

    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(isEdit ? 'Edit Activity' : 'Add Activity'),
            content: SingleChildScrollView(
              child: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Activity Title',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: timeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Time (HH:MM)',
                        border: OutlineInputBorder(),
                        hintText: '09:00',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: locationCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Location',
                        border: OutlineInputBorder(),
                        suffixIcon: Icon(Icons.location_on),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: notesCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Notes',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: selectedCategory,
                      decoration: const InputDecoration(
                        labelText: 'Category',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'Work', child: Text('Work')),
                        DropdownMenuItem(
                          value: 'Meeting',
                          child: Text('Meeting'),
                        ),
                        DropdownMenuItem(
                          value: 'Travel',
                          child: Text('Travel'),
                        ),
                        DropdownMenuItem(value: 'Meal', child: Text('Meal')),
                        DropdownMenuItem(
                          value: 'Activity',
                          child: Text('Activity'),
                        ),
                        DropdownMenuItem(value: 'Rest', child: Text('Rest')),
                      ],
                      onChanged: (value) {
                        selectedCategory = value ?? 'Activity';
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
                      activities.remove(existingActivity);
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
        _updateDayCount();
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
        _updateDayCount();
      });
    }
  }

  void _updateDayCount() {
    final newDayCount = _calculateDayCount();
    if (newDayCount != _dayCount) {
      _dayCount = newDayCount;

      // Recreate day tab controller
      _dayTabController.dispose();
      _dayTabController = TabController(
        length: _dayCount > 0 ? _dayCount : 1,
        vsync: this,
      );

      // Initialize itinerary if needed
      List<Map<String, dynamic>> itinerary = List<Map<String, dynamic>>.from(
        (_destData['itinerary'] as List<dynamic>? ?? []).map(
          (d) => Map<String, dynamic>.from(d as Map),
        ),
      );

      while (itinerary.length < _dayCount) {
        itinerary.add({
          'title': 'Day ${itinerary.length + 1}',
          'notes': '',
          'activities': [],
        });
      }

      _destData['itinerary'] = itinerary;
    }
  }

  void _showAIAssistant(String mode) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('AI Suggestions for $mode coming soon!')),
    );
  }
}
