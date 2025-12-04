import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/widgets/modern_widgets.dart';

/// Destination Detail Screen V4: Fixed text issues, calendar grid, start/end time, better saving
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

  // Store TextEditingControllers for accommodations
  final Map<int, TextEditingController> _accNameControllers = {};
  final Map<int, TextEditingController> _accAddressControllers = {};
  final Map<int, TextEditingController> _accPriceControllers = {};
  final Map<int, TextEditingController> _accRatingControllers = {};

  // Store TextEditingControllers for day titles/notes
  final Map<int, TextEditingController> _dayTitleControllers = {};
  final Map<int, TextEditingController> _dayNotesControllers = {};

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
    _initializeControllers();
  }

  void _initializeControllers() {
    // Initialize accommodation controllers
    final accommodations = _destData['accommodations'] as List<dynamic>? ?? [];
    for (int i = 0; i < accommodations.length; i++) {
      final acc = accommodations[i] as Map<String, dynamic>;
      _accNameControllers[i] = TextEditingController(text: acc['name'] ?? '');
      _accAddressControllers[i] = TextEditingController(
        text: acc['address'] ?? '',
      );
      _accPriceControllers[i] = TextEditingController(
        text: acc['price']?.toString() ?? '',
      );
      _accRatingControllers[i] = TextEditingController(
        text: acc['rating']?.toString() ?? '',
      );
    }

    // Initialize day controllers
    final itinerary = _destData['itinerary'] as List<dynamic>? ?? [];
    for (int i = 0; i < itinerary.length; i++) {
      final day = itinerary[i] as Map<String, dynamic>;
      _dayTitleControllers[i] = TextEditingController(text: day['title'] ?? '');
      _dayNotesControllers[i] = TextEditingController(text: day['notes'] ?? '');
    }
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
    if (_destData['itinerary'] == null ||
        (_destData['itinerary'] as List).isEmpty) {
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
    // Dispose all controllers
    _accNameControllers.forEach((_, ctrl) => ctrl.dispose());
    _accAddressControllers.forEach((_, ctrl) => ctrl.dispose());
    _accPriceControllers.forEach((_, ctrl) => ctrl.dispose());
    _accRatingControllers.forEach((_, ctrl) => ctrl.dispose());
    _dayTitleControllers.forEach((_, ctrl) => ctrl.dispose());
    _dayNotesControllers.forEach((_, ctrl) => ctrl.dispose());
    super.dispose();
  }

  Future<void> _saveChanges() async {
    if (_saving) return; // Prevent multiple concurrent saves
    setState(() => _saving = true);
    try {
      final tripRef = FirebaseFirestore.instance.doc(widget.tripRef);
      final snapshot = await tripRef.get();
      if (!snapshot.exists) {
        if (mounted) setState(() => _saving = false);
        throw Exception('Trip document not found');
      }

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

      // Use update instead of set for reliability
      await tripRef.update({'waypoints': waypoints});

      if (mounted) {
        // Re-fetch the data to ensure UI shows latest
        final refetchSnapshot = await tripRef.get();
        final refetchData = refetchSnapshot.data() ?? {};
        final refetchWaypoints =
            refetchData['waypoints'] as List<dynamic>? ?? [];

        setState(() {
          _saving = false;
          // Reload destination data from Firestore
          if (widget.destinationIndex >= 0 &&
              widget.destinationIndex < refetchWaypoints.length) {
            _destData = Map<String, dynamic>.from(
              refetchWaypoints[widget.destinationIndex] as Map,
            );
          }
        });

        // Show success message
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✓ Destination plan saved'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
    }
  }

  Future<void> _loadDestinationFromFirestore() async {
    try {
      final tripRef = FirebaseFirestore.instance.doc(widget.tripRef);
      final snapshot = await tripRef.get();
      if (!snapshot.exists) {
        throw Exception('Trip document not found');
      }

      final tripData = snapshot.data() ?? {};
      final waypoints = tripData['waypoints'] as List<dynamic>? ?? [];

      if (widget.destinationIndex >= 0 &&
          widget.destinationIndex < waypoints.length) {
        setState(() {
          // Reload destination data from Firestore
          _destData = Map<String, dynamic>.from(
            waypoints[widget.destinationIndex] as Map,
          );

          // Reset tab controllers to first tab
          _mainTabController.index = 0;

          // Recalculate day/week counts
          _dayCount = _calculateDayCount();
          _weekCount = (_dayCount / 7).ceil();
          _weekTabController.dispose();
          _weekTabController = TabController(
            length: _weekCount > 0 ? _weekCount : 1,
            vsync: this,
          );

          // Reinitialize all controllers with fresh data
          _accNameControllers.clear();
          _accAddressControllers.clear();
          _accPriceControllers.clear();
          _accRatingControllers.clear();
          _dayTitleControllers.clear();
          _dayNotesControllers.clear();
          _initializeControllers();
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✓ Page refreshed'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to refresh: $e')));
      }
    }
  }

  void _reinitializeControllers() {
    // Clear and reinitialize accommodation controllers
    _accNameControllers.forEach((_, ctrl) => ctrl.dispose());
    _accAddressControllers.forEach((_, ctrl) => ctrl.dispose());
    _accPriceControllers.forEach((_, ctrl) => ctrl.dispose());
    _accRatingControllers.forEach((_, ctrl) => ctrl.dispose());
    _accNameControllers.clear();
    _accAddressControllers.clear();
    _accPriceControllers.clear();
    _accRatingControllers.clear();

    final accommodations = _destData['accommodations'] as List<dynamic>? ?? [];
    for (int i = 0; i < accommodations.length; i++) {
      final acc = accommodations[i] as Map<String, dynamic>;
      _accNameControllers[i] = TextEditingController(text: acc['name'] ?? '');
      _accAddressControllers[i] = TextEditingController(
        text: acc['address'] ?? '',
      );
      _accPriceControllers[i] = TextEditingController(
        text: acc['price']?.toString() ?? '',
      );
      _accRatingControllers[i] = TextEditingController(
        text: acc['rating']?.toString() ?? '',
      );
    }

    // Clear and reinitialize day controllers
    _dayTitleControllers.forEach((_, ctrl) => ctrl.dispose());
    _dayNotesControllers.forEach((_, ctrl) => ctrl.dispose());
    _dayTitleControllers.clear();
    _dayNotesControllers.clear();

    final itinerary = _destData['itinerary'] as List<dynamic>? ?? [];
    for (int i = 0; i < itinerary.length; i++) {
      final day = itinerary[i] as Map<String, dynamic>;
      _dayTitleControllers[i] = TextEditingController(text: day['title'] ?? '');
      _dayNotesControllers[i] = TextEditingController(text: day['notes'] ?? '');
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
            child: GradientButton(
              onPressed: () {
                // Refresh: reload destination data from Firestore
                _loadDestinationFromFirestore();
              },
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh, size: 16),
                  SizedBox(width: 6),
                  Text('Refresh'),
                ],
              ),
            ),
          ),
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
    final accommodations = _destData['accommodations'] as List<dynamic>? ?? [];

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
            return _buildAccommodationCard(idx);
          }),
          const SizedBox(height: 16),
          GradientButton(
            onPressed: () {
              setState(() {
                final newAccs = List<Map<String, dynamic>>.from(
                  accommodations.map(
                    (a) => Map<String, dynamic>.from(a as Map),
                  ),
                );
                newAccs.add({
                  'name': '',
                  'address': '',
                  'price': 0,
                  'rating': 0,
                });
                _destData['accommodations'] = newAccs;
                // Initialize controllers for new accommodation
                _accNameControllers[accommodations.length] =
                    TextEditingController();
                _accAddressControllers[accommodations.length] =
                    TextEditingController();
                _accPriceControllers[accommodations.length] =
                    TextEditingController();
                _accRatingControllers[accommodations.length] =
                    TextEditingController();
              });
            },
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

  Widget _buildAccommodationCard(int index) {
    final accommodations = List<Map<String, dynamic>>.from(
      (_destData['accommodations'] as List<dynamic>? ?? []).map(
        (a) => Map<String, dynamic>.from(a as Map),
      ),
    );

    if (index >= accommodations.length) return const SizedBox();

    // Initialize controllers if needed
    _accNameControllers.putIfAbsent(
      index,
      () => TextEditingController(text: accommodations[index]['name'] ?? ''),
    );
    _accAddressControllers.putIfAbsent(
      index,
      () => TextEditingController(text: accommodations[index]['address'] ?? ''),
    );
    _accPriceControllers.putIfAbsent(
      index,
      () => TextEditingController(
        text: accommodations[index]['price']?.toString() ?? '',
      ),
    );
    _accRatingControllers.putIfAbsent(
      index,
      () => TextEditingController(
        text: accommodations[index]['rating']?.toString() ?? '',
      ),
    );

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
                  controller: _accNameControllers[index]!,
                  decoration: const InputDecoration(
                    labelText: 'Hotel Name',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    setState(() {
                      accommodations[index]['name'] = v;
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
                    // Dispose controller
                    _accNameControllers[index]?.dispose();
                    _accNameControllers.remove(index);
                    _accAddressControllers[index]?.dispose();
                    _accAddressControllers.remove(index);
                    _accPriceControllers[index]?.dispose();
                    _accPriceControllers.remove(index);
                    _accRatingControllers[index]?.dispose();
                    _accRatingControllers.remove(index);
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _accAddressControllers[index]!,
            decoration: const InputDecoration(
              labelText: 'Address',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              setState(() {
                accommodations[index]['address'] = v;
                _destData['accommodations'] = accommodations;
              });
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _accPriceControllers[index]!,
                  decoration: const InputDecoration(
                    labelText: 'Price per Night',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    setState(() {
                      accommodations[index]['price'] = double.tryParse(v) ?? 0;
                      _destData['accommodations'] = accommodations;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _accRatingControllers[index]!,
                  decoration: const InputDecoration(
                    labelText: 'Rating',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    setState(() {
                      accommodations[index]['rating'] = double.tryParse(v) ?? 0;
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

  // ============ ITINERARY MAIN TAB (WITH WEEK TABS) ============
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
        // Week tabbar
        TabBar(
          controller: _weekTabController,
          labelColor: Colors.black87,
          unselectedLabelColor: Colors.grey,
          indicatorColor: const Color(0xFF00695C),
          isScrollable: true,
          tabs: List.generate(_weekCount, (i) {
            final startDay = i * 7 + 1;
            final endDay = ((i + 1) * 7).clamp(0, _dayCount);
            return Tab(text: 'Week ${i + 1} (Days $startDay-$endDay)');
          }),
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

    // Calculate adaptive card width based on number of days
    // Available space minus padding
    final screenWidth = MediaQuery.of(context).size.width;
    final availableWidth = screenWidth - 32; // 16px padding on each side
    final cardWidth = (availableWidth / daysInWeek).clamp(400.0, 700.0);

    List<Map<String, dynamic>> itinerary = List<Map<String, dynamic>>.from(
      (_destData['itinerary'] as List<dynamic>? ?? []).map(
        (d) => Map<String, dynamic>.from(d as Map),
      ),
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: List.generate(daysInWeek, (localDayIndex) {
          final globalDayIndex = startDayIndex + localDayIndex;
          return Padding(
            padding: const EdgeInsets.only(right: 16),
            child: SizedBox(
              width: cardWidth,
              child: _buildDayCard(globalDayIndex, itinerary),
            ),
          );
        }),
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

    // Initialize controllers if needed
    _dayTitleControllers.putIfAbsent(
      dayIndex,
      () => TextEditingController(text: dayData['title'] ?? ''),
    );
    _dayNotesControllers.putIfAbsent(
      dayIndex,
      () => TextEditingController(text: dayData['notes'] ?? ''),
    );

    List<Map<String, dynamic>> activities = List<Map<String, dynamic>>.from(
      (dayData['activities'] as List<dynamic>? ?? []).map(
        (a) => Map<String, dynamic>.from(a as Map),
      ),
    );

    return GlassCard(
      padding: const EdgeInsets.all(16),
      borderRadius: 12,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Add activity button at top
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
            const SizedBox(height: 12),
            // Day title
            TextField(
              controller: _dayTitleControllers[dayIndex]!,
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
              controller: _dayNotesControllers[dayIndex]!,
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
            const SizedBox(height: 16),
            // Calendar grid view - only display activities here
            _buildCalendarGrid(activities, dayData, itinerary, dayIndex),
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
    const hourHeight = 80.0; // Height per hour in pixels

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: Column(
          children:
              hours.map((hour) {
                final hourStr = '${hour.toString().padLeft(2, '0')}:00';

                // Show activities that START in this hour only
                final hourActivities =
                    activities.where((a) {
                      final startTime = a['startTime'] as String? ?? '';
                      if (startTime.isEmpty) return false;

                      try {
                        final start = startTime.split(':');
                        final startMinutes =
                            int.parse(start[0]) * 60 + int.parse(start[1]);
                        final startHour = startMinutes ~/ 60;

                        return hour == startHour;
                      } catch (e) {
                        return false;
                      }
                    }).toList();

                return Container(
                  height: hourHeight,
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
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: Colors.grey),
                          ),
                        ),
                      ),
                      // Activities that start in this hour
                      Expanded(
                        child: Stack(
                          children:
                              hourActivities.map((activity) {
                                // Calculate height across all hours the activity spans
                                final startTime =
                                    activity['startTime'] as String? ?? '';
                                final endTime =
                                    activity['endTime'] as String? ?? '';

                                double activityHeight = hourHeight;
                                double topOffset = 0;

                                if (startTime.isNotEmpty &&
                                    endTime.isNotEmpty) {
                                  try {
                                    final start = startTime.split(':');
                                    final end = endTime.split(':');
                                    final startMinutes =
                                        int.parse(start[0]) * 60 +
                                        int.parse(start[1]);
                                    final endMinutes =
                                        int.parse(end[0]) * 60 +
                                        int.parse(end[1]);
                                    final durationMinutes =
                                        endMinutes - startMinutes;

                                    // Offset from top based on start time within the hour
                                    final minutesIntoHour = startMinutes % 60;
                                    topOffset =
                                        (minutesIntoHour / 60) * hourHeight;

                                    // Height = total duration converted to pixels
                                    activityHeight =
                                        (durationMinutes / 60.0) * hourHeight;
                                  } catch (e) {
                                    activityHeight = 0;
                                    topOffset = 0;
                                  }
                                }

                                if (activityHeight > 0) {
                                  return Positioned(
                                    left: 4,
                                    right: 4,
                                    top: topOffset,
                                    child: SizedBox(
                                      height: activityHeight - 4,
                                      child: _buildActivityChip(activity),
                                    ),
                                  );
                                }
                                return const SizedBox.shrink();
                              }).toList(),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
        ),
      ),
    );
  }

  Widget _buildActivityChip(Map<String, dynamic> activity) {
    final category = activity['category'] as String? ?? 'Hiking';
    final color = travelCategories[category] ?? Colors.teal;

    return GestureDetector(
      onTap: () {
        // Can be used to edit activity later
      },
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: color.withOpacity(0.8),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color, width: 1),
        ),
        padding: const EdgeInsets.all(6),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                activity['title'] ?? 'Untitled',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                '${activity['startTime'] ?? ''} - ${activity['endTime'] ?? ''}',
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
              if ((activity['location'] ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    activity['location'],
                    style: const TextStyle(color: Colors.white70, fontSize: 9),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
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
    final locationCtrl = TextEditingController(
      text: activity['location'] ?? '',
    );
    final notesCtrl = TextEditingController(text: activity['notes'] ?? '');
    String selectedCategory = activity['category'] ?? 'Hiking';
    String startTime = activity['startTime'] ?? '';
    String endTime = activity['endTime'] ?? '';

    showDialog(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setDialogState) => AlertDialog(
                  title: Text(isEdit ? 'Edit Activity' : 'Add Activity'),
                  content: SingleChildScrollView(
                    child: SizedBox(
                      width: 400,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Title
                          TextField(
                            controller: titleCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Activity Title',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          // Start Time picker (clock only)
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: Colors.grey.shade400,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Start Time',
                                        style:
                                            Theme.of(ctx).textTheme.labelSmall,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        startTime.isEmpty
                                            ? 'Not set'
                                            : startTime,
                                        style:
                                            Theme.of(ctx).textTheme.titleSmall,
                                      ),
                                    ],
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
                                    final formatted =
                                        '${timeOfDay.hour.toString().padLeft(2, '0')}:${timeOfDay.minute.toString().padLeft(2, '0')}';
                                    setDialogState(() {
                                      startTime = formatted;
                                    });
                                  }
                                },
                                child: const Icon(Icons.access_time, size: 20),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // End Time picker (clock only)
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: Colors.grey.shade400,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'End Time',
                                        style:
                                            Theme.of(ctx).textTheme.labelSmall,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        endTime.isEmpty ? 'Not set' : endTime,
                                        style:
                                            Theme.of(ctx).textTheme.titleSmall,
                                      ),
                                    ],
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
                                    final formatted =
                                        '${timeOfDay.hour.toString().padLeft(2, '0')}:${timeOfDay.minute.toString().padLeft(2, '0')}';
                                    setDialogState(() {
                                      endTime = formatted;
                                    });
                                  }
                                },
                                child: const Icon(Icons.access_time, size: 20),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Location
                          TextField(
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
                            items:
                                travelCategories.keys
                                    .map(
                                      (cat) => DropdownMenuItem(
                                        value: cat,
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 12,
                                              height: 12,
                                              decoration: BoxDecoration(
                                                color: travelCategories[cat],
                                                borderRadius:
                                                    BorderRadius.circular(2),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(cat),
                                          ],
                                        ),
                                      ),
                                    )
                                    .toList(),
                            onChanged: (value) {
                              setDialogState(() {
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
                        // Validate required fields
                        if (titleCtrl.text.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content: Text('Please enter an activity title'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                          return;
                        }
                        if (startTime.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content: Text('Please set a start time'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                          return;
                        }
                        if (endTime.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content: Text('Please set an end time'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                          return;
                        }

                        setState(() {
                          final newActivity = {
                            'title': titleCtrl.text,
                            'startTime': startTime,
                            'endTime': endTime,
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
