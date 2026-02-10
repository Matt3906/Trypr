import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/widgets/modern_widgets.dart';
import 'package:trypr/services/address_search.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// Trip Planning Workspace
///
/// A comprehensive trip‑level planning screen with:
///   1. Unified day‑by‑day Itinerary (across all stops)
///   2. Free‑form Notes (colour‑coded notebook)
///   3. Budget spreadsheet
///   4. Checklists (to‑do / prep lists)
///   5. Documents & important info storage
///
/// Data is stored as top‑level fields on the trip Firestore document so that
/// all participants see the same data in real‑time.
/// ─────────────────────────────────────────────────────────────────────────────
class TripPlanningScreen extends StatefulWidget {
  final String tripId;
  final String tripRefPath;
  final Map<String, dynamic> tripData;
  final int initialTab;
  final int? focusDayIndex;

  const TripPlanningScreen({
    super.key,
    required this.tripId,
    required this.tripRefPath,
    required this.tripData,
    this.initialTab = 0,
    this.focusDayIndex,
  });

  @override
  State<TripPlanningScreen> createState() => _TripPlanningScreenState();
}

class _TripPlanningScreenState extends State<TripPlanningScreen> {
  // ─── Navigation ───────────────────────────────────────────────────────────
  late int _selectedTab;
  bool _saving = false;
  late Map<String, dynamic> _tripData;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _tripSub;

  // ─── Itinerary ────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _itineraryDays = [];
  final ScrollController _itineraryScrollController = ScrollController();

  // ─── Notes ────────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _notes = [];
  int? _selectedNoteIndex;
  final _noteTitleCtrl = TextEditingController();
  final _noteContentCtrl = TextEditingController();

  // ─── Budget ───────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _budgetItems = [];
  String _currency = 'USD';

  // ─── Checklists ───────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _checklists = [];

  // ─── Documents ────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _documents = [];

  // ─── Constants ────────────────────────────────────────────────────────────
  static const _tabs = [
    _TabDef(icon: Icons.calendar_month, label: 'Itinerary'),
    _TabDef(icon: Icons.sticky_note_2_outlined, label: 'Notes'),
    _TabDef(icon: Icons.account_balance_wallet_outlined, label: 'Budget'),
    _TabDef(icon: Icons.checklist, label: 'Checklists'),
    _TabDef(icon: Icons.folder_outlined, label: 'Documents'),
  ];

  static const travelCategories = {
    'Hiking': Color(0xFF2E7D32),
    'Biking': Color(0xFF1565C0),
    'Walking': Color(0xFF00796B),
    'Museum': Color(0xFF6A1B9A),
    'Sightseeing': Color(0xFFF57C00),
    'Exploring': Color(0xFFC62828),
    'Restaurant': Color(0xFFD32F2F),
    'Shopping': Color(0xFF7B1FA2),
    'Photography': Color(0xFF0277BD),
    'Adventure': Color(0xFFFBC02D),
    'Driving': Color(0xFF448AFF),
    'Transit': Color(0xFF546E7A),
    'Free Time': Color(0xFF78909C),
  };

  static const categoryEmojis = {
    'Hiking': '🥾',
    'Biking': '🚴',
    'Walking': '🚶',
    'Museum': '🏛️',
    'Sightseeing': '📸',
    'Exploring': '🧭',
    'Restaurant': '🍽️',
    'Shopping': '🛍️',
    'Photography': '📷',
    'Adventure': '🏔️',
    'Driving': '🚗',
    'Transit': '🚆',
    'Free Time': '☕',
  };

  static const noteColors = [
    Color(0xFFFFFFFF),
    Color(0xFFFFF9C4),
    Color(0xFFB2DFDB),
    Color(0xFFBBDEFB),
    Color(0xFFF8BBD0),
    Color(0xFFD1C4E9),
    Color(0xFFFFCCBC),
    Color(0xFFC8E6C9),
  ];

  static const budgetCategories = [
    'Transport',
    'Accommodation',
    'Food & Drink',
    'Activities',
    'Shopping',
    'Insurance',
    'Visa & Documents',
    'Other',
  ];

  static const documentCategories = [
    'Flight',
    'Hotel',
    'Car Rental',
    'Insurance',
    'Emergency',
    'Visa',
    'Other',
  ];

  // ═════════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═════════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab.clamp(0, _tabs.length - 1);
    _tripData = Map<String, dynamic>.from(widget.tripData);
    _loadPlanningData();
    _subscribeToTrip();

    // Scroll to focused day after first frame
    if (widget.focusDayIndex != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToDay(widget.focusDayIndex!);
      });
    }
  }

  @override
  void dispose() {
    _tripSub?.cancel();
    _itineraryScrollController.dispose();
    _noteTitleCtrl.dispose();
    _noteContentCtrl.dispose();
    super.dispose();
  }

  // ═════════════════════════════════════════════════════════════════════════════
  // DATA LOADING
  // ═════════════════════════════════════════════════════════════════════════════

  void _loadPlanningData() {
    _itineraryDays = _loadOrGenerateItinerary();
    _notes = _mapList(_tripData['tripNotes']);

    final budget = _tripData['tripBudget'];
    if (budget is Map) {
      _currency = (budget['currency'] as String?) ?? 'USD';
      _budgetItems = _mapList(budget['items']);
    }

    _checklists = _mapList(_tripData['tripChecklists']);
    if (_checklists.isEmpty) _checklists = [_defaultChecklist()];

    _documents = _mapList(_tripData['tripDocuments']);
  }

  List<Map<String, dynamic>> _mapList(dynamic raw) {
    if (raw is! List) return [];
    return raw.map<Map<String, dynamic>>((e) {
      if (e is Map<String, dynamic>) return Map<String, dynamic>.from(e);
      if (e is Map) return Map<String, dynamic>.from(e.cast<String, dynamic>());
      return <String, dynamic>{};
    }).toList();
  }

  List<Map<String, dynamic>> _loadOrGenerateItinerary() {
    // If unified itinerary already exists, use it
    final existing = _tripData['tripItinerary'];
    if (existing is List && existing.isNotEmpty) {
      return _mapList(existing);
    }

    // Generate from trip dates
    final startStr = (_tripData['startDate'] ?? '').toString();
    final endStr = (_tripData['endDate'] ?? '').toString();
    if (startStr.isEmpty || endStr.isEmpty) return [];

    DateTime start, end;
    try {
      start = DateTime.parse(startStr);
      end = DateTime.parse(endStr);
    } catch (_) {
      return [];
    }

    final totalDays = end.difference(start).inDays + 1;
    if (totalDays <= 0) return [];

    final waypoints = _mapList(_tripData['waypoints']);

    // ── Helper: find the waypoint covering a given date ──
    (String name, int index) waypointForDate(DateTime date) {
      for (int w = 0; w < waypoints.length; w++) {
        final wpStart = (waypoints[w]['startDate'] ?? '').toString();
        final wpEnd = (waypoints[w]['endDate'] ?? '').toString();
        if (wpStart.isNotEmpty && wpEnd.isNotEmpty) {
          try {
            final ws = DateTime.parse(wpStart);
            final we = DateTime.parse(wpEnd);
            if (!date.isBefore(ws) && !date.isAfter(we)) {
              return ((waypoints[w]['name'] ?? 'Stop ${w + 1}').toString(), w);
            }
          } catch (_) {}
        }
      }
      return ('', -1);
    }

    // ── First pass: build raw day entries with location info ──
    final rawDays = <Map<String, dynamic>>[];
    for (int i = 0; i < totalDays; i++) {
      final date = start.add(Duration(days: i));
      final (locName, wpIdx) = waypointForDate(date);

      // Migrate existing per‑waypoint itinerary data
      List<Map<String, dynamic>> activities = [];
      if (wpIdx >= 0 && wpIdx < waypoints.length) {
        final wpItinerary = waypoints[wpIdx]['itinerary'];
        if (wpItinerary is List) {
          final wpStartStr = (waypoints[wpIdx]['startDate'] ?? '').toString();
          if (wpStartStr.isNotEmpty) {
            try {
              final wpStart = DateTime.parse(wpStartStr);
              final dayInWp = date.difference(wpStart).inDays;
              if (dayInWp >= 0 && dayInWp < wpItinerary.length) {
                final dayData = wpItinerary[dayInWp];
                if (dayData is Map) {
                  final acts = dayData['activities'];
                  if (acts is List) {
                    activities = _mapList(acts);
                  }
                }
              }
            } catch (_) {}
          }
        }
      }

      rawDays.add({
        'date': _ymd(date),
        'dayNumber': i + 1,
        'locationName': locName,
        'waypointIndex': wpIdx,
        'activities': activities,
        'notes': '',
      });
    }

    // ── Second pass: detect travel days ──
    // A travel day is when today's location differs from tomorrow's location.
    // We mark it with isTravel=true, travelFrom, travelTo.
    final days = <Map<String, dynamic>>[];
    for (int i = 0; i < rawDays.length; i++) {
      final day = rawDays[i];
      final loc = day['locationName'] as String;

      // Look at the next day's location
      String? nextLoc;
      if (i + 1 < rawDays.length) {
        nextLoc = rawDays[i + 1]['locationName'] as String;
      }

      final bool isTravel =
          loc.isNotEmpty &&
          nextLoc != null &&
          nextLoc.isNotEmpty &&
          loc != nextLoc;

      String title;
      if (isTravel) {
        title = 'Day ${day['dayNumber']} – Travel';
        day['isTravel'] = true;
        day['travelFrom'] = _shortName(loc);
        day['travelTo'] = _shortName(nextLoc);
      } else {
        title =
            loc.isNotEmpty
                ? 'Day ${day['dayNumber']} – $loc'
                : 'Day ${day['dayNumber']}';
        day['isTravel'] = false;
      }

      day['title'] = title;
      days.add(day);
    }

    return days;
  }

  /// Shorten a long location name for the travel banner.
  /// Keeps only the first meaningful part (before the first comma).
  String _shortName(String name) {
    if (name.length <= 40) return name;
    final comma = name.indexOf(',');
    if (comma > 0) return name.substring(0, comma);
    return '${name.substring(0, 37)}…';
  }

  Map<String, dynamic> _defaultChecklist() => {
    'id': _newId(),
    'title': 'Pre-Trip Preparation',
    'items': [
      {'id': _newId(), 'text': 'Book transportation', 'done': false},
      {'id': _newId(), 'text': 'Reserve accommodations', 'done': false},
      {'id': _newId(), 'text': 'Get travel insurance', 'done': false},
      {
        'id': _newId(),
        'text': 'Check passport / visa requirements',
        'done': false,
      },
      {'id': _newId(), 'text': 'Notify bank of travel dates', 'done': false},
      {'id': _newId(), 'text': 'Download offline maps', 'done': false},
    ],
  };

  // ═════════════════════════════════════════════════════════════════════════════
  // FIRESTORE SUBSCRIPTION & SAVE
  // ═════════════════════════════════════════════════════════════════════════════

  void _subscribeToTrip() {
    try {
      final ref = FirebaseFirestore.instance.doc(widget.tripRefPath);
      _tripSub = ref.snapshots().listen((snap) {
        if (!snap.exists || !mounted) return;
        final remote = snap.data() ?? {};
        setState(() {
          _tripData = Map<String, dynamic>.from(remote);
          // Re-load only if planning data was updated externally
          // (we compare lengths to avoid overwriting local edits every frame)
          final remoteItin = _tripData['tripItinerary'];
          if (remoteItin is List &&
              remoteItin.length != _itineraryDays.length) {
            _loadPlanningData();
          }
        });
      });
    } catch (_) {}
  }

  Future<void> _saveAll() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final ref = FirebaseFirestore.instance.doc(widget.tripRefPath);
      await ref.update({
        'tripItinerary': _itineraryDays,
        'tripNotes': _notes,
        'tripBudget': {'currency': _currency, 'items': _budgetItems},
        'tripChecklists': _checklists,
        'tripDocuments': _documents,
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Trip plan saved ✓')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ═════════════════════════════════════════════════════════════════════════════
  // HELPERS
  // ═════════════════════════════════════════════════════════════════════════════

  String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toString() +
      (identityHashCode(this) % 9999).toString();

  static String _ymd(DateTime dt) => dt.toIso8601String().split('T').first;

  String _formatDisplayDate(String dateStr) {
    try {
      final d = DateTime.parse(dateStr);
      const months = [
        '',
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return '${weekdays[d.weekday - 1]}, ${months[d.month]} ${d.day}';
    } catch (_) {
      return dateStr;
    }
  }

  void _scrollToDay(int dayIndex) {
    if (_itineraryDays.isEmpty) return;
    // Rough estimate: each day card ≈ 200px height
    final offset = (dayIndex * 220.0).clamp(
      0.0,
      _itineraryScrollController.position.maxScrollExtent,
    );
    _itineraryScrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  // ═════════════════════════════════════════════════════════════════════════════
  // BUILD — MAIN LAYOUT
  // ═════════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 800;
    final tripName =
        (_tripData['name'] ?? widget.tripData['name'] ?? 'Trip Plan')
            .toString();

    if (isWide) {
      return Scaffold(
        backgroundColor: TryprColors.background,
        body: Row(
          children: [
            _buildSidebar(tripName),
            const VerticalDivider(width: 1),
            Expanded(child: _buildTabContent()),
          ],
        ),
      );
    }

    // Narrow / mobile layout
    return Scaffold(
      backgroundColor: TryprColors.background,
      appBar: AppBar(
        title: Text(tripName, overflow: TextOverflow.ellipsis),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: 'Save all',
              icon: const Icon(Icons.save),
              onPressed: _saveAll,
            ),
        ],
      ),
      body: _buildTabContent(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTab,
        onTap: (i) => setState(() => _selectedTab = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: TryprColors.primary,
        unselectedItemColor: TryprColors.textTertiary,
        items:
            _tabs
                .map(
                  (t) => BottomNavigationBarItem(
                    icon: Icon(t.icon),
                    label: t.label,
                  ),
                )
                .toList(),
      ),
    );
  }

  // ─── Sidebar (wide layout) ───────────────────────────────────────────────
  Widget _buildSidebar(String tripName) {
    return Container(
      width: 220,
      color: TryprColors.surface,
      child: Column(
        children: [
          const SizedBox(height: 16),
          // Back button + title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back to trip',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    tripName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // Navigation items
          ..._tabs.asMap().entries.map((e) {
            final idx = e.key;
            final tab = e.value;
            final selected = _selectedTab == idx;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Material(
                color:
                    selected
                        ? TryprColors.primary.withValues(alpha: 0.1)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => _selectedTab = idx),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          tab.icon,
                          size: 20,
                          color:
                              selected
                                  ? TryprColors.primary
                                  : TryprColors.textSecondary,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          tab.label,
                          style: TextStyle(
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w500,
                            color:
                                selected
                                    ? TryprColors.primary
                                    : TryprColors.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
          const Spacer(),
          // Save button
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: GradientButton(
                onPressed: _saveAll,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_saving)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                    else
                      const Icon(Icons.save, size: 18),
                    const SizedBox(width: 8),
                    Text(_saving ? 'Saving…' : 'Save All'),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ─── Tab router ──────────────────────────────────────────────────────────
  Widget _buildTabContent() {
    switch (_selectedTab) {
      case 0:
        return _buildItineraryTab();
      case 1:
        return _buildNotesTab();
      case 2:
        return _buildBudgetTab();
      case 3:
        return _buildChecklistsTab();
      case 4:
        return _buildDocumentsTab();
      default:
        return _buildItineraryTab();
    }
  }

  // ─── Date Picker ───────────────────────────────────────────────────────────
  Future<void> _pickTripDates() async {
    final startStr = (_tripData['startDate'] ?? '').toString();
    final endStr = (_tripData['endDate'] ?? '').toString();

    DateTime? initialStart;
    DateTime? initialEnd;
    try {
      if (startStr.isNotEmpty) initialStart = DateTime.parse(startStr);
      if (endStr.isNotEmpty) initialEnd = DateTime.parse(endStr);
    } catch (_) {}

    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 5),
      initialDateRange:
          (initialStart != null && initialEnd != null)
              ? DateTimeRange(start: initialStart, end: initialEnd)
              : null,
      builder: (ctx, child) {
        return Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: Theme.of(ctx).colorScheme.copyWith(
              primary: TryprColors.primary,
              onPrimary: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked == null || !mounted) return;

    final newStart = _ymd(picked.start);
    final newEnd = _ymd(picked.end);

    setState(() {
      _tripData['startDate'] = newStart;
      _tripData['endDate'] = newEnd;
      // Regenerate itinerary days for the new date range
      _itineraryDays = _loadOrGenerateItinerary();
    });

    // Persist dates + regenerated itinerary to Firestore immediately
    try {
      final ref = FirebaseFirestore.instance.doc(widget.tripRefPath);
      await ref.update({
        'startDate': newStart,
        'endDate': newEnd,
        'tripItinerary': _itineraryDays,
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Trip dates updated ✓')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save dates: $e')));
      }
    }
  }

  Widget _buildDateRow() {
    final startStr = (_tripData['startDate'] ?? '').toString();
    final endStr = (_tripData['endDate'] ?? '').toString();

    String label;
    if (startStr.isEmpty && endStr.isEmpty) {
      label = 'Tap to set trip dates';
    } else {
      final s = startStr.isNotEmpty ? _formatDisplayDate(startStr) : '?';
      final e = endStr.isNotEmpty ? _formatDisplayDate(endStr) : '?';
      final days =
          (startStr.isNotEmpty && endStr.isNotEmpty)
              ? DateTime.parse(
                    endStr,
                  ).difference(DateTime.parse(startStr)).inDays +
                  1
              : 0;
      label = '$s  →  $e${days > 0 ? '  ($days days)' : ''}';
    }

    return GestureDetector(
      onTap: _pickTripDates,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: TryprColors.primary.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: TryprColors.primary.withValues(alpha: 0.25),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.date_range, size: 20, color: TryprColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color:
                      (startStr.isEmpty)
                          ? TryprColors.textTertiary
                          : TryprColors.textPrimary,
                ),
              ),
            ),
            Icon(
              Icons.edit_calendar,
              size: 18,
              color: TryprColors.primary.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════════
  //  TAB 1 — ITINERARY (Unified day-by-day)
  // ═════════════════════════════════════════════════════════════════════════════

  Widget _buildItineraryTab() {
    if (_itineraryDays.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_today,
              size: 48,
              color: TryprColors.textTertiary,
            ),
            const SizedBox(height: 12),
            const Text(
              'No itinerary yet',
              style: TextStyle(fontSize: 16, color: TryprColors.textSecondary),
            ),
            const SizedBox(height: 4),
            const Text(
              'Set trip dates to generate your day-by-day itinerary.',
              style: TextStyle(color: TryprColors.textTertiary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _pickTripDates,
              icon: const Icon(Icons.date_range),
              label: const Text('Set Trip Dates'),
              style: ElevatedButton.styleFrom(
                backgroundColor: TryprColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Day quick‑jump chips
    final jumpChips = SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _itineraryDays.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (ctx, i) {
          final day = _itineraryDays[i];
          final loc = (day['locationName'] ?? '').toString();
          final isTravel = day['isTravel'] == true;
          return ActionChip(
            avatar:
                isTravel ? const Icon(Icons.directions_car, size: 14) : null,
            label: Text(
              isTravel
                  ? 'D${i + 1} 🚗'
                  : (loc.isNotEmpty
                      ? 'D${i + 1} · ${_shortName(loc)}'
                      : 'Day ${i + 1}'),
              style: const TextStyle(fontSize: 12),
            ),
            visualDensity: VisualDensity.compact,
            onPressed: () => _scrollToDay(i),
          );
        },
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Trip Itinerary',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 8),
        _buildDateRow(),
        const SizedBox(height: 8),
        jumpChips,
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            controller: _itineraryScrollController,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
            itemCount: _itineraryDays.length,
            itemBuilder: (ctx, i) => _buildDayCard(i),
          ),
        ),
      ],
    );
  }

  Widget _buildDayCard(int dayIndex) {
    final day = _itineraryDays[dayIndex];
    final dateStr = (day['date'] ?? '').toString();
    final dayNum = (day['dayNumber'] ?? dayIndex + 1);
    final location = (day['locationName'] ?? '').toString();
    final title = (day['title'] ?? '').toString();
    final notes = (day['notes'] ?? '').toString();
    final activities = _mapList(day['activities']);
    final isTravel = day['isTravel'] == true;
    final travelFrom = (day['travelFrom'] ?? '').toString();
    final travelTo = (day['travelTo'] ?? '').toString();

    return GlassCard(
      padding: const EdgeInsets.all(16),
      borderRadius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row ──
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color:
                      isTravel
                          ? Colors.orange.withValues(alpha: 0.15)
                          : TryprColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child:
                      isTravel
                          ? const Icon(
                            Icons.directions_car,
                            size: 20,
                            color: Colors.orange,
                          )
                          : Text(
                            '$dayNum',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: TryprColors.primary,
                            ),
                          ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (dateStr.isNotEmpty)
                      Text(
                        _formatDisplayDate(dateStr),
                        style: const TextStyle(
                          fontSize: 12,
                          color: TryprColors.textTertiary,
                        ),
                      ),
                    if (isTravel) ...[
                      // Travel day location row
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on,
                            size: 14,
                            color: Colors.orange,
                          ),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              'Travel Day',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: Colors.orange,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ] else if (location.isNotEmpty) ...[
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on,
                            size: 14,
                            color: TryprColors.primary,
                          ),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              location,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 22),
                tooltip: 'Add activity',
                onPressed: () => _showAddActivityDialog(dayIndex),
              ),
            ],
          ),

          // ── Travel banner ──
          if (isTravel && travelFrom.isNotEmpty && travelTo.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.orange.withValues(alpha: 0.08),
                    Colors.amber.withValues(alpha: 0.06),
                  ],
                ),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'FROM',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: TryprColors.textTertiary,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          travelFrom,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(
                      Icons.arrow_forward,
                      color: Colors.orange.withValues(alpha: 0.6),
                      size: 22,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'TO',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: TryprColors.textTertiary,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          travelTo,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 8),
          // ── Editable title ──
          TextField(
            controller: TextEditingController(text: title)
              ..selection = TextSelection.collapsed(offset: title.length),
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            decoration: const InputDecoration(
              hintText: 'Day title…',
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 6),
            ),
            onChanged: (v) => _itineraryDays[dayIndex]['title'] = v,
          ),
          // ── Editable notes ──
          TextField(
            controller: TextEditingController(text: notes)
              ..selection = TextSelection.collapsed(offset: notes.length),
            style: const TextStyle(
              fontSize: 13,
              color: TryprColors.textSecondary,
            ),
            decoration: const InputDecoration(
              hintText: 'Notes for this day…',
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 4),
            ),
            maxLines: 3,
            minLines: 1,
            onChanged: (v) => _itineraryDays[dayIndex]['notes'] = v,
          ),
          if (activities.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Divider(height: 1),
            const SizedBox(height: 6),
            ...activities.asMap().entries.map((e) {
              final a = e.value;
              final cat = (a['category'] ?? 'Exploring').toString();
              final color = travelCategories[cat] ?? TryprColors.secondary;
              final emoji = categoryEmojis[cat] ?? '📌';
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showEditActivityDialog(dayIndex, e.key, a),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: color.withValues(alpha: 0.25)),
                    ),
                    child: Row(
                      children: [
                        Text(emoji, style: const TextStyle(fontSize: 18)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                (a['title'] ?? 'Activity').toString(),
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: color,
                                ),
                              ),
                              if ((a['startTime'] ?? '').toString().isNotEmpty)
                                Text(
                                  '${a['startTime']} – ${a['endTime'] ?? ''}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: TryprColors.textTertiary,
                                  ),
                                ),
                              if ((a['location'] ?? '').toString().isNotEmpty)
                                Text(
                                  (a['location']).toString(),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: TryprColors.textTertiary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: TryprColors.error,
                          ),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            setState(() {
                              final acts = _mapList(
                                _itineraryDays[dayIndex]['activities'],
                              );
                              acts.removeAt(e.key);
                              _itineraryDays[dayIndex]['activities'] = acts;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  // ── Add / Edit activity dialogs ──────────────────────────────────────────

  void _showAddActivityDialog(int dayIndex) {
    _showActivityFormDialog(dayIndex: dayIndex);
  }

  void _showEditActivityDialog(
    int dayIndex,
    int activityIndex,
    Map<String, dynamic> existing,
  ) {
    _showActivityFormDialog(
      dayIndex: dayIndex,
      activityIndex: activityIndex,
      existing: existing,
    );
  }

  void _showActivityFormDialog({
    required int dayIndex,
    int? activityIndex,
    Map<String, dynamic>? existing,
  }) {
    final isEdit = existing != null;
    final titleCtrl = TextEditingController(
      text: existing?['title']?.toString() ?? '',
    );
    final locationCtrl = TextEditingController(
      text: existing?['location']?.toString() ?? '',
    );
    final notesCtrl = TextEditingController(
      text: existing?['notes']?.toString() ?? '',
    );
    String category = existing?['category']?.toString() ?? 'Exploring';
    String startTime = existing?['startTime']?.toString() ?? '';
    String endTime = existing?['endTime']?.toString() ?? '';
    double? locationLat = (existing?['locationLat'] as num?)?.toDouble();
    double? locationLon = (existing?['locationLon'] as num?)?.toDouble();
    List<AddressSuggestion> locSuggestions = [];
    bool locLoading = false;
    Timer? locDebounce;

    showDialog(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setD) => AlertDialog(
                  title: Text(isEdit ? 'Edit Activity' : 'Add Activity'),
                  content: SingleChildScrollView(
                    child: SizedBox(
                      width: 420,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextField(
                            controller: titleCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Activity title',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 10),
                          // Time pickers
                          Row(
                            children: [
                              Expanded(
                                child: _timeTile(ctx, 'Start', startTime, (t) {
                                  setD(() => startTime = t);
                                }),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _timeTile(ctx, 'End', endTime, (t) {
                                  setD(() => endTime = t);
                                }),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // Location with search
                          TextField(
                            controller: locationCtrl,
                            decoration: InputDecoration(
                              labelText: 'Location',
                              border: const OutlineInputBorder(),
                              suffixIcon:
                                  locLoading
                                      ? const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      )
                                      : null,
                            ),
                            onChanged: (v) {
                              locDebounce?.cancel();
                              if (v.trim().isEmpty) {
                                setD(() {
                                  locSuggestions = [];
                                  locLoading = false;
                                });
                                return;
                              }
                              locDebounce = Timer(
                                const Duration(milliseconds: 350),
                                () async {
                                  setD(() => locLoading = true);
                                  final results =
                                      await AddressSearchService.search(
                                        v.trim(),
                                      );
                                  if (!mounted) return;
                                  setD(() {
                                    locSuggestions = results;
                                    locLoading = false;
                                  });
                                },
                              );
                            },
                          ),
                          if (locSuggestions.isNotEmpty)
                            Container(
                              constraints: const BoxConstraints(maxHeight: 150),
                              margin: const EdgeInsets.only(top: 4),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: locSuggestions.length,
                                itemBuilder: (_, i) {
                                  final s = locSuggestions[i];
                                  return ListTile(
                                    dense: true,
                                    title: Text(
                                      s.displayName,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () {
                                      setD(() {
                                        locationCtrl.text = s.displayName;
                                        locationLat = s.lat;
                                        locationLon = s.lon;
                                        locSuggestions = [];
                                      });
                                    },
                                  );
                                },
                              ),
                            ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: notesCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Notes',
                              border: OutlineInputBorder(),
                            ),
                            maxLines: 3,
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<String>(
                            initialValue:
                                travelCategories.containsKey(category)
                                    ? category
                                    : 'Exploring',
                            decoration: const InputDecoration(
                              labelText: 'Category',
                              border: OutlineInputBorder(),
                            ),
                            items:
                                travelCategories.keys
                                    .map(
                                      (c) => DropdownMenuItem(
                                        value: c,
                                        child: Row(
                                          children: [
                                            Text(
                                              categoryEmojis[c] ?? '📌',
                                              style: const TextStyle(
                                                fontSize: 16,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Text(c),
                                          ],
                                        ),
                                      ),
                                    )
                                    .toList(),
                            onChanged:
                                (v) => setD(() => category = v ?? 'Exploring'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        locDebounce?.cancel();
                        Navigator.pop(ctx);
                      },
                      child: const Text('Cancel'),
                    ),
                    if (isEdit)
                      TextButton(
                        onPressed: () {
                          locDebounce?.cancel();
                          setState(() {
                            final acts = _mapList(
                              _itineraryDays[dayIndex]['activities'],
                            );
                            if (activityIndex != null &&
                                activityIndex < acts.length) {
                              acts.removeAt(activityIndex);
                            }
                            _itineraryDays[dayIndex]['activities'] = acts;
                          });
                          Navigator.pop(ctx);
                        },
                        child: const Text(
                          'Delete',
                          style: TextStyle(color: TryprColors.error),
                        ),
                      ),
                    GradientButton(
                      onPressed: () {
                        locDebounce?.cancel();
                        if (titleCtrl.text.trim().isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content: Text('Please enter an activity title'),
                            ),
                          );
                          return;
                        }
                        final activity = <String, dynamic>{
                          'title': titleCtrl.text.trim(),
                          'startTime': startTime,
                          'endTime': endTime,
                          'location': locationCtrl.text.trim(),
                          'notes': notesCtrl.text.trim(),
                          'category': category,
                          if (locationLat != null) 'locationLat': locationLat,
                          if (locationLon != null) 'locationLon': locationLon,
                        };
                        setState(() {
                          final acts = _mapList(
                            _itineraryDays[dayIndex]['activities'],
                          );
                          if (isEdit &&
                              activityIndex != null &&
                              activityIndex < acts.length) {
                            acts[activityIndex] = activity;
                          } else {
                            acts.add(activity);
                          }
                          _itineraryDays[dayIndex]['activities'] = acts;
                        });
                        Navigator.pop(ctx);
                      },
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      child: const Text('Save'),
                    ),
                  ],
                ),
          ),
    );
  }

  Widget _timeTile(
    BuildContext ctx,
    String label,
    String value,
    ValueChanged<String> onPicked,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final initial = _parseTime(value);
        final t = await showTimePicker(context: ctx, initialTime: initial);
        if (t != null) {
          onPicked(
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade400),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: TryprColors.textTertiary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value.isEmpty ? 'Tap to set' : value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color:
                    value.isEmpty
                        ? TryprColors.textTertiary
                        : TryprColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  TimeOfDay _parseTime(String s) {
    try {
      final parts = s.split(':');
      return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    } catch (_) {
      return TimeOfDay.now();
    }
  }

  // ═════════════════════════════════════════════════════════════════════════════
  //  TAB 2 — NOTES
  // ═════════════════════════════════════════════════════════════════════════════

  Widget _buildNotesTab() {
    final isWide = MediaQuery.sizeOf(context).width >= 800;

    if (isWide) {
      // Side-by-side: list + editor
      return Row(
        children: [
          SizedBox(width: 260, child: _buildNotesList()),
          const VerticalDivider(width: 1),
          Expanded(child: _buildNoteEditor()),
        ],
      );
    }

    // Mobile: show list if nothing selected, else editor
    if (_selectedNoteIndex != null) {
      return _buildNoteEditor(showBack: true);
    }
    return _buildNotesList();
  }

  Widget _buildNotesList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Text(
                'Notes',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'New note',
                onPressed: () {
                  setState(() {
                    _notes.add({
                      'id': _newId(),
                      'title': '',
                      'content': '',
                      'color': '#FFFFFF',
                      'createdAt': DateTime.now().toIso8601String(),
                    });
                    _selectedNoteIndex = _notes.length - 1;
                    _syncNoteControllers();
                  });
                },
              ),
            ],
          ),
        ),
        Expanded(
          child:
              _notes.isEmpty
                  ? const Center(
                    child: Text(
                      'No notes yet.\nTap + to create one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: TryprColors.textTertiary),
                    ),
                  )
                  : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _notes.length,
                    itemBuilder: (ctx, i) {
                      final n = _notes[i];
                      final colorHex = (n['color'] ?? '#FFFFFF').toString();
                      final color = _parseHexColor(colorHex);
                      final selected = _selectedNoteIndex == i;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color:
                              selected
                                  ? TryprColors.primary.withValues(alpha: 0.08)
                                  : color,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              setState(() {
                                _selectedNoteIndex = i;
                                _syncNoteControllers();
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.sticky_note_2_outlined,
                                    size: 18,
                                    color: TryprColors.textSecondary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      (n['title'] ?? '').toString().isNotEmpty
                                          ? n['title'].toString()
                                          : 'Untitled Note',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight:
                                            selected
                                                ? FontWeight.w600
                                                : FontWeight.w500,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 16,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () {
                                      setState(() {
                                        _notes.removeAt(i);
                                        if (_selectedNoteIndex == i) {
                                          _selectedNoteIndex = null;
                                        } else if (_selectedNoteIndex != null &&
                                            _selectedNoteIndex! > i) {
                                          _selectedNoteIndex =
                                              _selectedNoteIndex! - 1;
                                        }
                                      });
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }

  Widget _buildNoteEditor({bool showBack = false}) {
    if (_selectedNoteIndex == null || _selectedNoteIndex! >= _notes.length) {
      return const Center(
        child: Text(
          'Select a note to edit',
          style: TextStyle(color: TryprColors.textTertiary),
        ),
      );
    }

    final note = _notes[_selectedNoteIndex!];
    final colorHex = (note['color'] ?? '#FFFFFF').toString();
    final bgColor = _parseHexColor(colorHex);

    return Container(
      color: bgColor.withValues(alpha: 0.3),
      child: Column(
        children: [
          // Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                if (showBack)
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => setState(() => _selectedNoteIndex = null),
                  ),
                Expanded(
                  child: TextField(
                    controller: _noteTitleCtrl,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Note title…',
                      border: InputBorder.none,
                    ),
                    onChanged: (v) => _notes[_selectedNoteIndex!]['title'] = v,
                  ),
                ),
              ],
            ),
          ),
          // Color selector
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children:
                  noteColors.map((c) {
                    final hex = _colorToHex(c);
                    final selected =
                        colorHex.toLowerCase() == hex.toLowerCase();
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _notes[_selectedNoteIndex!]['color'] = hex;
                          });
                        },
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color:
                                  selected
                                      ? TryprColors.primary
                                      : Colors.grey.shade300,
                              width: selected ? 2.5 : 1,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
            ),
          ),
          const SizedBox(height: 8),
          // Content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _noteContentCtrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: 'Write your notes here…',
                  border: InputBorder.none,
                ),
                onChanged: (v) => _notes[_selectedNoteIndex!]['content'] = v,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _syncNoteControllers() {
    if (_selectedNoteIndex != null && _selectedNoteIndex! < _notes.length) {
      final n = _notes[_selectedNoteIndex!];
      _noteTitleCtrl.text = (n['title'] ?? '').toString();
      _noteContentCtrl.text = (n['content'] ?? '').toString();
    }
  }

  Color _parseHexColor(String hex) {
    try {
      final h = hex.replaceFirst('#', '');
      if (h.length == 6) return Color(int.parse('FF$h', radix: 16));
    } catch (_) {}
    return Colors.white;
  }

  String _colorToHex(Color c) {
    final argb = c.toARGB32();
    return '#${argb.toRadixString(16).substring(2).toUpperCase()}';
  }

  // ═════════════════════════════════════════════════════════════════════════════
  //  TAB 3 — BUDGET
  // ═════════════════════════════════════════════════════════════════════════════

  Widget _buildBudgetTab() {
    double totalEstimated = 0;
    double totalActual = 0;
    for (final item in _budgetItems) {
      totalEstimated += (item['estimated'] as num?)?.toDouble() ?? 0;
      totalActual += (item['actual'] as num?)?.toDouble() ?? 0;
    }
    final diff = totalEstimated - totalActual;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              const Text(
                'Trip Budget',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const Spacer(),
              // Currency selector
              DropdownButton<String>(
                value: _currency,
                underline: const SizedBox(),
                items:
                    [
                          'USD',
                          'EUR',
                          'GBP',
                          'CAD',
                          'AUD',
                          'JPY',
                          'SEK',
                          'NOK',
                          'CHF',
                        ]
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                onChanged: (v) => setState(() => _currency = v ?? 'USD'),
              ),
              const SizedBox(width: 8),
              GradientButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                onPressed: () {
                  setState(() {
                    _budgetItems.add({
                      'id': _newId(),
                      'description': '',
                      'category': 'Other',
                      'estimated': 0.0,
                      'actual': 0.0,
                      'notes': '',
                    });
                  });
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 16),
                    SizedBox(width: 4),
                    Text('Add Item'),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Summary bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GlassCard(
            padding: const EdgeInsets.all(12),
            borderRadius: 10,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _budgetSummaryCell(
                  'Estimated',
                  totalEstimated,
                  TryprColors.textPrimary,
                ),
                _budgetSummaryCell(
                  'Actual',
                  totalActual,
                  TryprColors.textPrimary,
                ),
                _budgetSummaryCell(
                  diff >= 0 ? 'Under budget' : 'Over budget',
                  diff.abs(),
                  diff >= 0 ? TryprColors.success : TryprColors.error,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Table
        Expanded(
          child:
              _budgetItems.isEmpty
                  ? const Center(
                    child: Text(
                      'No budget items yet.\nTap "Add Item" to start.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: TryprColors.textTertiary),
                    ),
                  )
                  : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                    itemCount: _budgetItems.length,
                    itemBuilder: (ctx, i) => _buildBudgetRow(i),
                  ),
        ),
      ],
    );
  }

  Widget _budgetSummaryCell(String label, double value, Color color) {
    final sym = _currencySymbol(_currency);
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: TryprColors.textTertiary),
        ),
        const SizedBox(height: 2),
        Text(
          '$sym${value.toStringAsFixed(2)}',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 16,
            color: color,
          ),
        ),
      ],
    );
  }

  String _currencySymbol(String code) {
    const map = {
      'USD': '\$',
      'EUR': '€',
      'GBP': '£',
      'CAD': 'CA\$',
      'AUD': 'A\$',
      'JPY': '¥',
      'SEK': 'kr',
      'NOK': 'kr',
      'CHF': 'CHF ',
    };
    return map[code] ?? '\$';
  }

  Widget _buildBudgetRow(int index) {
    final item = _budgetItems[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(10),
        borderRadius: 10,
        child: Column(
          children: [
            Row(
              children: [
                // Description
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: TextEditingController(
                        text: (item['description'] ?? '').toString(),
                      )
                      ..selection = TextSelection.collapsed(
                        offset: (item['description'] ?? '').toString().length,
                      ),
                    decoration: const InputDecoration(
                      hintText: 'Description',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (v) => _budgetItems[index]['description'] = v,
                  ),
                ),
                const SizedBox(width: 6),
                // Category
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        budgetCategories.contains(item['category']?.toString())
                            ? item['category'].toString()
                            : 'Other',
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                    style: const TextStyle(fontSize: 13, color: Colors.black87),
                    items:
                        budgetCategories
                            .map(
                              (c) => DropdownMenuItem(value: c, child: Text(c)),
                            )
                            .toList(),
                    onChanged:
                        (v) => setState(
                          () => _budgetItems[index]['category'] = v ?? 'Other',
                        ),
                  ),
                ),
                const SizedBox(width: 6),
                // Estimated
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: TextEditingController(
                        text: _numStr(item['estimated']),
                      )
                      ..selection = TextSelection.collapsed(
                        offset: _numStr(item['estimated']).length,
                      ),
                    decoration: const InputDecoration(
                      hintText: 'Est.',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 13),
                    onChanged:
                        (v) =>
                            _budgetItems[index]['estimated'] =
                                double.tryParse(v) ?? 0,
                  ),
                ),
                const SizedBox(width: 6),
                // Actual
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: TextEditingController(
                        text: _numStr(item['actual']),
                      )
                      ..selection = TextSelection.collapsed(
                        offset: _numStr(item['actual']).length,
                      ),
                    decoration: const InputDecoration(
                      hintText: 'Actual',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 13),
                    onChanged:
                        (v) =>
                            _budgetItems[index]['actual'] =
                                double.tryParse(v) ?? 0,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: TryprColors.error,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _budgetItems.removeAt(index)),
                ),
              ],
            ),
            // Optional notes row
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: TextField(
                controller: TextEditingController(
                    text: (item['notes'] ?? '').toString(),
                  )
                  ..selection = TextSelection.collapsed(
                    offset: (item['notes'] ?? '').toString().length,
                  ),
                decoration: const InputDecoration(
                  hintText: 'Notes…',
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
                style: const TextStyle(
                  fontSize: 12,
                  color: TryprColors.textTertiary,
                ),
                onChanged: (v) => _budgetItems[index]['notes'] = v,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _numStr(dynamic n) {
    if (n == null) return '';
    if (n is num)
      return n == 0 ? '' : n.toStringAsFixed(n == n.roundToDouble() ? 0 : 2);
    return n.toString();
  }

  // ═════════════════════════════════════════════════════════════════════════════
  //  TAB 4 — CHECKLISTS
  // ═════════════════════════════════════════════════════════════════════════════

  Widget _buildChecklistsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Text(
                'Checklists',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const Spacer(),
              GradientButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                onPressed: () {
                  setState(() {
                    _checklists.add({
                      'id': _newId(),
                      'title': 'New List',
                      'items': <Map<String, dynamic>>[],
                    });
                  });
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 16),
                    SizedBox(width: 4),
                    Text('New List'),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child:
              _checklists.isEmpty
                  ? const Center(
                    child: Text(
                      'No checklists yet.',
                      style: TextStyle(color: TryprColors.textTertiary),
                    ),
                  )
                  : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                    itemCount: _checklists.length,
                    itemBuilder: (ctx, i) => _buildChecklistCard(i),
                  ),
        ),
      ],
    );
  }

  Widget _buildChecklistCard(int listIndex) {
    final cl = _checklists[listIndex];
    final title = (cl['title'] ?? 'Untitled').toString();
    final items = _mapList(cl['items']);
    final doneCount = items.where((it) => it['done'] == true).length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        borderRadius: 12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title + progress + delete
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: TextEditingController(text: title)
                      ..selection = TextSelection.collapsed(
                        offset: title.length,
                      ),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (v) => _checklists[listIndex]['title'] = v,
                  ),
                ),
                Text(
                  '$doneCount / ${items.length}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: TryprColors.textTertiary,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed:
                      () => setState(() => _checklists.removeAt(listIndex)),
                ),
              ],
            ),
            if (items.isNotEmpty) ...[
              // Progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: items.isEmpty ? 0 : doneCount / items.length,
                  minHeight: 4,
                  backgroundColor: TryprColors.surfaceVariant,
                  valueColor: const AlwaysStoppedAnimation(TryprColors.success),
                ),
              ),
              const SizedBox(height: 8),
            ],
            // Items
            ...items.asMap().entries.map((e) {
              final idx = e.key;
              final item = e.value;
              final done = item['done'] == true;
              final text = (item['text'] ?? '').toString();
              return Row(
                children: [
                  Checkbox(
                    value: done,
                    onChanged: (v) {
                      setState(() {
                        final updatedItems = _mapList(
                          _checklists[listIndex]['items'],
                        );
                        updatedItems[idx]['done'] = v ?? false;
                        _checklists[listIndex]['items'] = updatedItems;
                      });
                    },
                    visualDensity: VisualDensity.compact,
                  ),
                  Expanded(
                    child: TextField(
                      controller: TextEditingController(text: text)
                        ..selection = TextSelection.collapsed(
                          offset: text.length,
                        ),
                      style: TextStyle(
                        fontSize: 13,
                        decoration: done ? TextDecoration.lineThrough : null,
                        color:
                            done
                                ? TryprColors.textTertiary
                                : TryprColors.textPrimary,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: (v) {
                        final updatedItems = _mapList(
                          _checklists[listIndex]['items'],
                        );
                        updatedItems[idx]['text'] = v;
                        _checklists[listIndex]['items'] = updatedItems;
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 14),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setState(() {
                        final updatedItems = _mapList(
                          _checklists[listIndex]['items'],
                        );
                        updatedItems.removeAt(idx);
                        _checklists[listIndex]['items'] = updatedItems;
                      });
                    },
                  ),
                ],
              );
            }),
            // Add item
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _ChecklistAddField(
                onAdd: (text) {
                  setState(() {
                    final updatedItems = _mapList(
                      _checklists[listIndex]['items'],
                    );
                    updatedItems.add({
                      'id': _newId(),
                      'text': text,
                      'done': false,
                    });
                    _checklists[listIndex]['items'] = updatedItems;
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════════
  //  TAB 5 — DOCUMENTS & INFO
  // ═════════════════════════════════════════════════════════════════════════════

  Widget _buildDocumentsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Text(
                'Documents & Info',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const Spacer(),
              GradientButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                onPressed: () => _showDocumentDialog(),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 16),
                    SizedBox(width: 4),
                    Text('Add'),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child:
              _documents.isEmpty
                  ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.folder_open,
                          size: 48,
                          color: TryprColors.textTertiary,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'No documents yet.\nStore flight info, hotel confirmations,\nemergency contacts, and more.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: TryprColors.textTertiary),
                        ),
                      ],
                    ),
                  )
                  : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                    itemCount: _documents.length,
                    itemBuilder: (ctx, i) => _buildDocumentCard(i),
                  ),
        ),
      ],
    );
  }

  static const _docCategoryEmojis = {
    'Flight': '✈️',
    'Hotel': '🏨',
    'Car Rental': '🚗',
    'Insurance': '🛡️',
    'Emergency': '🆘',
    'Visa': '🛂',
    'Other': '📄',
  };

  Widget _buildDocumentCard(int index) {
    final doc = _documents[index];
    final cat = (doc['category'] ?? 'Other').toString();
    final emoji = _docCategoryEmojis[cat] ?? '📄';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        borderRadius: 12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(emoji, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (doc['title'] ?? 'Untitled').toString(),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        cat,
                        style: const TextStyle(
                          fontSize: 11,
                          color: TryprColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed:
                      () => _showDocumentDialog(index: index, existing: doc),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: TryprColors.error,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _documents.removeAt(index)),
                ),
              ],
            ),
            if ((doc['content'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: TryprColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  (doc['content'] ?? '').toString(),
                  style: const TextStyle(
                    fontSize: 13,
                    color: TryprColors.textSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showDocumentDialog({int? index, Map<String, dynamic>? existing}) {
    final isEdit = existing != null;
    final titleCtrl = TextEditingController(
      text: existing?['title']?.toString() ?? '',
    );
    final contentCtrl = TextEditingController(
      text: existing?['content']?.toString() ?? '',
    );
    String category = existing?['category']?.toString() ?? 'Other';

    showDialog(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setD) => AlertDialog(
                  title: Text(isEdit ? 'Edit Document' : 'Add Document'),
                  content: SizedBox(
                    width: 420,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          controller: titleCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Title',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue:
                              documentCategories.contains(category)
                                  ? category
                                  : 'Other',
                          decoration: const InputDecoration(
                            labelText: 'Category',
                            border: OutlineInputBorder(),
                          ),
                          items:
                              documentCategories
                                  .map(
                                    (c) => DropdownMenuItem(
                                      value: c,
                                      child: Row(
                                        children: [
                                          Text(
                                            _docCategoryEmojis[c] ?? '📄',
                                            style: const TextStyle(
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(c),
                                        ],
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (v) => setD(() => category = v ?? 'Other'),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: contentCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Details',
                            border: OutlineInputBorder(),
                            hintText:
                                'Confirmation numbers, addresses, phone numbers…',
                          ),
                          maxLines: 6,
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    GradientButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      onPressed: () {
                        if (titleCtrl.text.trim().isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content: Text('Please enter a title'),
                            ),
                          );
                          return;
                        }
                        final entry = {
                          'id': existing?['id'] ?? _newId(),
                          'title': titleCtrl.text.trim(),
                          'content': contentCtrl.text.trim(),
                          'category': category,
                        };
                        setState(() {
                          if (isEdit &&
                              index != null &&
                              index < _documents.length) {
                            _documents[index] = entry;
                          } else {
                            _documents.add(entry);
                          }
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
}

// ═════════════════════════════════════════════════════════════════════════════
//  HELPERS
// ═════════════════════════════════════════════════════════════════════════════

class _TabDef {
  final IconData icon;
  final String label;
  const _TabDef({required this.icon, required this.label});
}

/// Small stateful widget for the "add item" text field inside a checklist,
/// so we can clear it after adding without rebuilding the whole tree.
class _ChecklistAddField extends StatefulWidget {
  final ValueChanged<String> onAdd;
  const _ChecklistAddField({required this.onAdd});

  @override
  State<_ChecklistAddField> createState() => _ChecklistAddFieldState();
}

class _ChecklistAddFieldState extends State<_ChecklistAddField> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 36), // align with checkboxes
        Expanded(
          child: TextField(
            controller: _ctrl,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'Add item…',
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            onSubmitted: (v) {
              if (v.trim().isEmpty) return;
              widget.onAdd(v.trim());
              _ctrl.clear();
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline, size: 18),
          visualDensity: VisualDensity.compact,
          onPressed: () {
            if (_ctrl.text.trim().isEmpty) return;
            widget.onAdd(_ctrl.text.trim());
            _ctrl.clear();
          },
        ),
      ],
    );
  }
}
