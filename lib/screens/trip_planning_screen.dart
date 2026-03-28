import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill_extensions/flutter_quill_extensions.dart';
import 'package:image_picker/image_picker.dart';
import 'package:trypr/models/budget_person.dart';
import 'package:trypr/services/pick_file_data_url.dart';
import 'package:trypr/services/open_external_url.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/widgets/modern_widgets.dart';
import 'package:trypr/services/address_search.dart';
import 'package:trypr/services/route_options.dart';
import 'package:trypr/widgets/map_embed.dart';
import 'package:trypr/widgets/web_interceptor.dart';

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
  bool _autoSaveInFlight = false;
  late Map<String, dynamic> _tripData;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _tripSub;
  Timer? _autoSaveTimer;
  String _lastPersistedSignature = '';

  Widget _overlaySafe(Widget child) {
    if (!kIsWeb) return child;
    return WebInterceptor(child: child);
  }

  // ─── Itinerary ────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _itineraryDays = [];
  final ScrollController _itineraryScrollController = ScrollController();
  int _selectedItineraryDayIndex = 0;
  Map<String, dynamic>? _selectedItineraryMapPoint;
  bool _updatingTravelRecommendations = false;
  int _travelRecommendationRunId = 0;
  final Map<int, TextEditingController> _dayTitleCtrls = {};
  final Map<int, TextEditingController> _dayNotesCtrls = {};

  // ─── Notes ────────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _notes = [];
  int? _selectedNoteIndex;
  final _noteTitleCtrl = TextEditingController();
  final FocusNode _noteEditorFocus = FocusNode();
  final ScrollController _noteEditorScroll = ScrollController();
  quill.QuillController? _noteContentQuillCtrl;
  String? _boundNoteId;

  // ─── Budget ───────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _budgetItems = [];
  List<BudgetPerson> _budgetPeople = [];
  int _budgetFinalSplitByCount = 0;
  String _currency = 'USD';
  final TextEditingController _budgetPersonCtrl = TextEditingController();

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
    _lastPersistedSignature = _planningSignature();
    _subscribeToTrip();
    _autoSaveTimer = Timer.periodic(
      const Duration(seconds: 6),
      (_) => _autoSaveTick(),
    );

    // Scroll to focused day after first frame
    if (widget.focusDayIndex != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToDay(widget.focusDayIndex!);
      });
    }
  }

  @override
  void dispose() {
    _disposeNoteEditorController();
    _tripSub?.cancel();
    _autoSaveTimer?.cancel();
    _itineraryScrollController.dispose();
    for (final c in _dayTitleCtrls.values) {
      c.dispose();
    }
    for (final c in _dayNotesCtrls.values) {
      c.dispose();
    }
    _noteTitleCtrl.dispose();
    _budgetPersonCtrl.dispose();
    _noteEditorFocus.dispose();
    _noteEditorScroll.dispose();
    super.dispose();
  }

  // ═════════════════════════════════════════════════════════════════════════════
  // DATA LOADING
  // ═════════════════════════════════════════════════════════════════════════════

  void _loadPlanningData() {
    _itineraryDays = _normalizeItineraryDays(_loadOrGenerateItinerary());
    _syncItineraryControllers();
    _notes = _mapList(_tripData['tripNotes']);
    if (_notes.isEmpty) {
      _selectedNoteIndex = null;
    } else if (_selectedNoteIndex != null) {
      _selectedNoteIndex = _selectedNoteIndex!.clamp(0, _notes.length - 1);
    }
    _syncNoteControllers();

    final budget = _tripData['tripBudget'];
    if (budget is Map) {
      _currency = (budget['currency'] as String?) ?? 'USD';
      _budgetItems = _mapList(budget['items']);
      _budgetPeople = parseBudgetPeople(budget['people']);
      _budgetFinalSplitByCount = _parseBudgetFinalSplitCount(
        budget['finalSplitByCount'],
      );
    } else {
      _currency = 'USD';
      _budgetItems = [];
      _budgetPeople = const <BudgetPerson>[];
      _budgetFinalSplitByCount = 0;
    }

    _checklists = _mapList(_tripData['tripChecklists']);
    if (_checklists.isEmpty) _checklists = [_defaultChecklist()];

    _documents = _mapList(_tripData['tripDocuments']);
    if (_itineraryDays.isEmpty) {
      _selectedItineraryDayIndex = 0;
    } else {
      _selectedItineraryDayIndex = _selectedItineraryDayIndex.clamp(
        0,
        _itineraryDays.length - 1,
      );
    }

    unawaited(_refreshTravelRecommendations(persist: false));
    _lastPersistedSignature = _planningSignature();
  }

  List<Map<String, dynamic>> _mapList(dynamic raw) {
    if (raw is! List) return [];
    return raw.map<Map<String, dynamic>>((e) {
      if (e is Map<String, dynamic>) return Map<String, dynamic>.from(e);
      if (e is Map) return Map<String, dynamic>.from(e.cast<String, dynamic>());
      return <String, dynamic>{};
    }).toList();
  }

  void _disposeNoteEditorController() {
    _noteContentQuillCtrl?.removeListener(_onNoteEditorChanged);
    _noteContentQuillCtrl?.dispose();
    _noteContentQuillCtrl = null;
    _boundNoteId = null;
  }

  String _ensureNoteId(Map<String, dynamic> note) {
    final existing = (note['id'] ?? '').toString().trim();
    if (existing.isNotEmpty) return existing;
    final created = _newId();
    note['id'] = created;
    return created;
  }

  String _normalizeNotePlainText(String text) {
    var out = text;
    while (out.endsWith('\n')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  List<dynamic>? _parseNoteDelta(dynamic raw) {
    if (raw is List) return raw;
    if (raw is Map && raw['ops'] is List) return raw['ops'] as List;
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded;
        if (decoded is Map && decoded['ops'] is List) {
          return decoded['ops'] as List;
        }
      } catch (_) {}
    }
    return null;
  }

  quill.Document _documentFromNote(Map<String, dynamic> note) {
    final deltaOps = _parseNoteDelta(note['contentDelta']);
    if (deltaOps != null && deltaOps.isNotEmpty) {
      try {
        final jsonOps = deltaOps
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e.cast<String, dynamic>()))
            .toList(growable: false);
        if (jsonOps.isNotEmpty) {
          return quill.Document.fromJson(jsonOps);
        }
      } catch (_) {}
    }

    final plain = (note['content'] ?? '').toString();
    final doc = quill.Document();
    if (plain.isNotEmpty) {
      doc.insert(0, plain);
    }
    return doc;
  }

  int _boundNoteIndex() {
    if (_boundNoteId == null) return -1;
    return _notes.indexWhere((n) => (n['id'] ?? '').toString() == _boundNoteId);
  }

  void _persistBoundNoteEditorState() {
    final controller = _noteContentQuillCtrl;
    if (controller == null) return;
    final idx = _boundNoteIndex();
    if (idx < 0 || idx >= _notes.length) return;
    final note = _notes[idx];
    note['contentDelta'] = controller.document.toDelta().toJson();
    note['content'] = _normalizeNotePlainText(
      controller.document.toPlainText(),
    );
    note['updatedAt'] = DateTime.now().toIso8601String();
  }

  void _onNoteEditorChanged() {
    _persistBoundNoteEditorState();
  }

  void _bindNoteEditorForSelection() {
    if (_selectedNoteIndex == null || _selectedNoteIndex! >= _notes.length) {
      _disposeNoteEditorController();
      return;
    }
    final note = _notes[_selectedNoteIndex!];
    final noteId = _ensureNoteId(note);
    if (_boundNoteId == noteId && _noteContentQuillCtrl != null) {
      return;
    }

    _persistBoundNoteEditorState();
    _disposeNoteEditorController();

    final doc = _documentFromNote(note);
    final selectionOffset = doc.length > 0 ? doc.length - 1 : 0;
    final controller = quill.QuillController(
      document: doc,
      selection: TextSelection.collapsed(offset: selectionOffset),
    );
    controller.addListener(_onNoteEditorChanged);
    _noteContentQuillCtrl = controller;
    _boundNoteId = noteId;
  }

  double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? double.nan;
    return double.nan;
  }

  bool _isValidLatLon(double lat, double lon) {
    return lat.isFinite &&
        lon.isFinite &&
        lat >= -90 &&
        lat <= 90 &&
        lon >= -180 &&
        lon <= 180;
  }

  int _timeToSortValue(String value) {
    final parts = value.trim().split(':');
    if (parts.length != 2) return 1 << 30;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return 1 << 30;
    }
    return h * 60 + m;
  }

  List<Map<String, dynamic>> _sortActivitiesByStartTime(
    List<Map<String, dynamic>> activities,
  ) {
    final indexed = activities.asMap().entries.toList();
    indexed.sort((a, b) {
      final av = _timeToSortValue((a.value['startTime'] ?? '').toString());
      final bv = _timeToSortValue((b.value['startTime'] ?? '').toString());
      if (av != bv) return av.compareTo(bv);
      return a.key.compareTo(b.key);
    });
    return indexed.map((e) => e.value).toList();
  }

  List<Map<String, dynamic>> _normalizeItineraryDays(
    List<Map<String, dynamic>> days,
  ) {
    return days.map((d) {
      final day = Map<String, dynamic>.from(d);
      day['activities'] = _sortActivitiesByStartTime(
        _mapList(day['activities']),
      );
      return day;
    }).toList();
  }

  void _syncItineraryControllers() {
    for (var i = 0; i < _itineraryDays.length; i++) {
      final day = _itineraryDays[i];
      final title = (day['title'] ?? '').toString();
      final notes = (day['notes'] ?? '').toString();

      final titleCtrl = _dayTitleCtrls.putIfAbsent(
        i,
        () => TextEditingController(text: title),
      );
      if (titleCtrl.text != title) titleCtrl.text = title;

      final notesCtrl = _dayNotesCtrls.putIfAbsent(
        i,
        () => TextEditingController(text: notes),
      );
      if (notesCtrl.text != notes) notesCtrl.text = notes;
    }

    final staleTitleKeys =
        _dayTitleCtrls.keys.where((k) => k >= _itineraryDays.length).toList();
    for (final k in staleTitleKeys) {
      _dayTitleCtrls.remove(k)?.dispose();
    }
    final staleNotesKeys =
        _dayNotesCtrls.keys.where((k) => k >= _itineraryDays.length).toList();
    for (final k in staleNotesKeys) {
      _dayNotesCtrls.remove(k)?.dispose();
    }
  }

  TextEditingController _dayTitleControllerFor(int dayIndex) {
    final day = _itineraryDays[dayIndex];
    return _dayTitleCtrls.putIfAbsent(
      dayIndex,
      () => TextEditingController(text: (day['title'] ?? '').toString()),
    );
  }

  TextEditingController _dayNotesControllerFor(int dayIndex) {
    final day = _itineraryDays[dayIndex];
    return _dayNotesCtrls.putIfAbsent(
      dayIndex,
      () => TextEditingController(text: (day['notes'] ?? '').toString()),
    );
  }

  List<Map<String, dynamic>> _mapRoutePoints() {
    final waypoints = _mapList(_tripData['waypoints']);
    final out = <Map<String, dynamic>>[];
    for (final entry in waypoints.asMap().entries) {
      final w = entry.value;
      final lat = _toDouble(w['lat'] ?? w['latitude']);
      final lon = _toDouble(w['lon'] ?? w['longitude'] ?? w['lng']);
      if (!_isValidLatLon(lat, lon)) continue;
      out.add({
        'lat': lat,
        'lon': lon,
        'name': (w['name'] ?? '').toString(),
        'pointType': 'waypoint',
        'waypointIndex': entry.key,
      });
    }
    return out;
  }

  int _waypointNights(Map<String, dynamic> waypoint) {
    final raw = waypoint['nights'];
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  bool _waypointCountsAsStay(List<Map<String, dynamic>> waypoints, int index) {
    if (index < 0 || index >= waypoints.length) return false;
    if (index == 0 || index == waypoints.length - 1) return true;
    final raw = waypoints[index]['isStop'];
    if (raw is bool) return raw;
    return _waypointNights(waypoints[index]) > 0;
  }

  List<Map<String, dynamic>> _mapItineraryActivityPins() {
    final pins = <Map<String, dynamic>>[];
    for (final dayEntry in _itineraryDays.asMap().entries) {
      final dayIndex = dayEntry.key;
      final day = dayEntry.value;
      final activities = _mapList(day['activities']);
      for (final actEntry in activities.asMap().entries) {
        final act = actEntry.value;
        final lat = _toDouble(act['locationLat']);
        final lon = _toDouble(act['locationLon']);
        if (!_isValidLatLon(lat, lon)) continue;
        pins.add({
          'lat': lat,
          'lon': lon,
          'kind': 'activity',
          'category': (act['category'] ?? 'Exploring').toString(),
          'name': (act['title'] ?? 'Activity').toString(),
          'dayIndex': dayIndex,
          'activityIndex': actEntry.key,
        });
      }
    }
    return pins;
  }

  String _normalizedLabel(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _labelsMatch(String a, String b) {
    final na = _normalizedLabel(a);
    final nb = _normalizedLabel(b);
    return na.isNotEmpty && na == nb;
  }

  String _itineraryMapPointKind(Map<String, dynamic> point) {
    final kind =
        (point['kind'] ?? point['pointType'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
    if (kind.isNotEmpty) return kind;
    if (point['waypointIndex'] != null) return 'waypoint';
    return 'location';
  }

  String _itineraryMapPointTitle(Map<String, dynamic> point) {
    final title = (point['name'] ?? point['title'] ?? '').toString().trim();
    if (title.isNotEmpty) return title;
    final waypointIndex = (point['waypointIndex'] as num?)?.toInt();
    if (waypointIndex != null && waypointIndex >= 0) {
      return 'Stop ${waypointIndex + 1}';
    }
    return 'Selected place';
  }

  List<Map<String, dynamic>> _activitiesForWaypointPoint(
    int waypointIndex, {
    String? waypointName,
  }) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    final safeName = (waypointName ?? '').toString().trim();
    for (final day in _itineraryDays) {
      final dayWaypointIndex = (day['waypointIndex'] as num?)?.toInt();
      final dayLocationName = (day['locationName'] ?? '').toString();
      final matchesWaypoint =
          waypointIndex >= 0 && dayWaypointIndex == waypointIndex;
      final matchesName =
          safeName.isNotEmpty && _labelsMatch(dayLocationName, safeName);
      if (!matchesWaypoint && !matchesName) continue;
      final activities = _mapList(day['activities']);
      for (final activity in activities) {
        final key = [
          (activity['title'] ?? '').toString().trim().toLowerCase(),
          (activity['startTime'] ?? '').toString().trim(),
          (activity['location'] ?? '').toString().trim().toLowerCase(),
          (activity['category'] ?? '').toString().trim().toLowerCase(),
        ].join('|');
        if (!seen.add(key)) continue;
        out.add(activity);
      }
    }
    return out;
  }

  List<String> _topCategoriesForActivities(
    Iterable<Map<String, dynamic>> activities, {
    int max = 6,
  }) {
    final counts = <String, int>{};
    for (final activity in activities) {
      final raw = (activity['category'] ?? '').toString().trim();
      if (raw.isEmpty) continue;
      counts[raw] = (counts[raw] ?? 0) + 1;
    }
    final sorted =
        counts.entries.toList()..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          if (byCount != 0) return byCount;
          return a.key.compareTo(b.key);
        });
    return sorted.take(max).map((entry) => entry.key).toList(growable: false);
  }

  List<String> _categoriesForItineraryMapPoint(Map<String, dynamic> point) {
    final kind = _itineraryMapPointKind(point);
    final category = (point['category'] ?? '').toString().trim();

    if (kind == 'activity') {
      final out = <String>[];
      if (category.isNotEmpty) out.add(category);
      final dayIndex = (point['dayIndex'] as num?)?.toInt();
      if (dayIndex != null &&
          dayIndex >= 0 &&
          dayIndex < _itineraryDays.length) {
        final dayCategories = _topCategoriesForActivities(
          _mapList(_itineraryDays[dayIndex]['activities']),
        );
        for (final dayCategory in dayCategories) {
          if (!out.contains(dayCategory)) out.add(dayCategory);
        }
      }
      return out.take(6).toList(growable: false);
    }

    final waypointIndex = (point['waypointIndex'] as num?)?.toInt() ?? -1;
    final waypointName = (point['name'] ?? '').toString();
    final activities = _activitiesForWaypointPoint(
      waypointIndex,
      waypointName: waypointName,
    );
    final categories = _topCategoriesForActivities(activities);
    if (categories.isNotEmpty) return categories;
    if (category.isNotEmpty) return [category];
    return const [];
  }

  String _itineraryMapPointSubtitle(Map<String, dynamic> point) {
    final kind = _itineraryMapPointKind(point);
    final category = (point['category'] ?? '').toString().trim();
    final dayIndex = (point['dayIndex'] as num?)?.toInt();

    if (kind == 'activity') {
      final dayText =
          dayIndex != null && dayIndex >= 0 && dayIndex < _itineraryDays.length
              ? 'Day ${(_itineraryDays[dayIndex]['dayNumber'] ?? dayIndex + 1)}'
              : '';
      final parts = [
        if (dayText.isNotEmpty) dayText,
        if (category.isNotEmpty) category,
      ];
      return parts.join(' • ');
    }
    if (kind == 'waypoint') {
      final waypointIndex = (point['waypointIndex'] as num?)?.toInt();
      if (waypointIndex != null && waypointIndex >= 0) {
        return 'Stop ${waypointIndex + 1}';
      }
    }
    return category.isNotEmpty ? category : 'Map selection';
  }

  String _itineraryAiSummaryForPoint(
    Map<String, dynamic> point,
    List<String> categories,
  ) {
    final kind = _itineraryMapPointKind(point);
    final title = _itineraryMapPointTitle(point);

    if (kind == 'activity') {
      final dayIndex = (point['dayIndex'] as num?)?.toInt();
      final dayText =
          dayIndex != null && dayIndex >= 0 && dayIndex < _itineraryDays.length
              ? 'on Day ${(_itineraryDays[dayIndex]['dayNumber'] ?? dayIndex + 1)}'
              : 'in your itinerary';
      final category =
          (point['category'] ?? (categories.isNotEmpty ? categories.first : ''))
              .toString()
              .trim();
      final categoryText = category.isEmpty ? 'general exploration' : category;
      return '$title is planned $dayText and fits a $categoryText focus. Keep this near your other stops to reduce transit time.';
    }

    final waypointIndex = (point['waypointIndex'] as num?)?.toInt() ?? -1;
    final activities = _activitiesForWaypointPoint(
      waypointIndex,
      waypointName: title,
    );
    if (activities.isEmpty) {
      return '$title is currently a routing anchor. Add activities here to build a stronger day plan.';
    }
    final dayCount =
        _itineraryDays.where((day) {
          final dayWaypoint = (day['waypointIndex'] as num?)?.toInt();
          final dayLoc = (day['locationName'] ?? '').toString();
          return (waypointIndex >= 0 && dayWaypoint == waypointIndex) ||
              _labelsMatch(dayLoc, title);
        }).length;
    final categoryText =
        categories.isEmpty ? 'mixed activities' : categories.take(3).join(', ');
    final dayText =
        dayCount > 0
            ? '$dayCount planned day${dayCount == 1 ? '' : 's'}'
            : 'this stop';
    return '$title has ${activities.length} planned activit${activities.length == 1 ? 'y' : 'ies'} across $dayText, focused on $categoryText.';
  }

  void _handleItineraryMapPointTap(Map<String, dynamic> point) {
    setState(() {
      _selectedItineraryMapPoint = Map<String, dynamic>.from(point);
    });
  }

  Widget _buildItineraryMapInsightCard() {
    final point = _selectedItineraryMapPoint;
    if (point == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x14000000)),
        ),
        child: const Text(
          'Tap a map pin to view a place summary and activity categories.',
          style: TextStyle(fontSize: 12, color: TryprColors.textSecondary),
        ),
      );
    }

    final title = _itineraryMapPointTitle(point);
    final subtitle = _itineraryMapPointSubtitle(point);
    final categories = _categoriesForItineraryMapPoint(point);
    final summary = _itineraryAiSummaryForPoint(point, categories);
    final kind = _itineraryMapPointKind(point);
    final icon =
        kind == 'activity'
            ? Icons.local_activity
            : kind == 'waypoint'
            ? Icons.location_city
            : Icons.place;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x14000000)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: TryprColors.textPrimary),
              const SizedBox(width: 6),
              const Text(
                'Place Insight',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              const Icon(
                Icons.auto_awesome,
                size: 14,
                color: TryprColors.textSecondary,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 12,
                color: TryprColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            'AI Summary',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            summary,
            style: const TextStyle(
              fontSize: 12,
              color: TryprColors.textPrimary,
            ),
          ),
          if (categories.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'Activity Categories',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: categories
                  .take(6)
                  .map(
                    (category) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${categoryEmojis[category] ?? '📌'} $category',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _loadOrGenerateItinerary({
    bool forceRegenerate = false,
    List<Map<String, dynamic>>? carryFromDays,
  }) {
    // If unified itinerary already exists, use it
    final existing = _tripData['tripItinerary'];
    if (!forceRegenerate && existing is List && existing.isNotEmpty) {
      return _mapList(existing);
    }

    final carryDays = <String, Map<String, dynamic>>{};
    final carrySource = carryFromDays ?? _mapList(existing);
    for (final d in carrySource) {
      final key = (d['date'] ?? '').toString().trim();
      if (key.isEmpty) continue;
      carryDays[key] = Map<String, dynamic>.from(d);
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
        if (!_waypointCountsAsStay(waypoints, w)) continue;
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

    for (final day in days) {
      final dateKey = (day['date'] ?? '').toString();
      final previous = carryDays[dateKey];
      if (previous == null) continue;
      if (previous['activities'] is List) {
        day['activities'] = _sortActivitiesByStartTime(
          _mapList(previous['activities']),
        );
      }
      day['notes'] = (previous['notes'] ?? '').toString();
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

  String _normalizeTransportMode(String raw) {
    final mode = raw.trim().toLowerCase();
    switch (mode) {
      case 'flying':
        return 'flying';
      case 'train':
      case 'rail':
      case 'public_transit':
      case 'public transit':
      case 'transit':
        return 'transit';
      case 'walking':
      case 'hiking':
      case 'portaging':
      case 'biking':
      case 'bikepacking':
      case 'backpacking':
      case 'driving':
        return mode;
      case 'canoe':
      case 'canoeing':
      case 'portage':
        return 'portaging';
      default:
        return 'driving';
    }
  }

  String _segmentTransportModeFor(int segmentIndex) {
    final fallback = _normalizeTransportMode(
      (_tripData['transportMode'] ?? 'driving').toString(),
    );
    if (segmentIndex < 0) return fallback;
    final raw = _tripData['segmentTransportModes'];
    if (raw is! List || segmentIndex >= raw.length) return fallback;
    return _normalizeTransportMode(raw[segmentIndex].toString());
  }

  int _resolveWaypointIndexForDay(
    Map<String, dynamic> day,
    List<Map<String, dynamic>> waypoints,
  ) {
    final direct = (day['waypointIndex'] as num?)?.toInt();
    if (direct != null && direct >= 0 && direct < waypoints.length) {
      return direct;
    }

    final date = _tryParseDate((day['date'] ?? '').toString());
    if (date != null) {
      for (var i = 0; i < waypoints.length; i++) {
        if (!_waypointCountsAsStay(waypoints, i)) continue;
        final wpStart = _tryParseDate(
          (waypoints[i]['startDate'] ?? '').toString(),
        );
        final wpEnd = _tryParseDate((waypoints[i]['endDate'] ?? '').toString());
        if (wpStart == null || wpEnd == null) continue;
        final ds = DateTime(date.year, date.month, date.day);
        final ws = DateTime(wpStart.year, wpStart.month, wpStart.day);
        final we = DateTime(wpEnd.year, wpEnd.month, wpEnd.day);
        if (!ds.isBefore(ws) && !ds.isAfter(we)) return i;
      }
    }

    final loc = (day['locationName'] ?? '').toString().trim().toLowerCase();
    if (loc.isNotEmpty) {
      for (var i = 0; i < waypoints.length; i++) {
        if (!_waypointCountsAsStay(waypoints, i)) continue;
        final wp = (waypoints[i]['name'] ?? '').toString().trim().toLowerCase();
        if (wp.isEmpty) continue;
        if (wp == loc || wp.contains(loc) || loc.contains(wp)) return i;
      }
    }

    return -1;
  }

  Map<String, double>? _waypointCoords(
    List<Map<String, dynamic>> waypoints,
    int index,
  ) {
    if (index < 0 || index >= waypoints.length) return null;
    final wp = waypoints[index];
    final lat = _toDouble(wp['lat'] ?? wp['latitude']);
    final lon = _toDouble(wp['lon'] ?? wp['lng'] ?? wp['longitude']);
    if (!_isValidLatLon(lat, lon)) return null;
    return {'lat': lat, 'lon': lon};
  }

  int _segmentIndexForTravel({
    required int fromIndex,
    required int toIndex,
    required int waypointCount,
  }) {
    if (waypointCount < 2) return -1;
    if (fromIndex >= 0 && toIndex >= 0) {
      if (toIndex == fromIndex + 1) return fromIndex;
      if (fromIndex == toIndex + 1) return toIndex;
    }
    if (fromIndex >= 0 && fromIndex < waypointCount - 1) return fromIndex;
    if (toIndex > 0 && (toIndex - 1) < waypointCount - 1) return toIndex - 1;
    return -1;
  }

  String _travelModeLabel(String mode) {
    switch (_normalizeTransportMode(mode)) {
      case 'transit':
        return 'Transit';
      case 'walking':
      case 'hiking':
      case 'backpacking':
        return 'Walking';
      case 'portaging':
        return 'Portaging';
      case 'biking':
      case 'bikepacking':
        return 'Biking';
      case 'flying':
        return 'Flight';
      default:
        return 'Driving';
    }
  }

  IconData _travelModeIcon(String mode) {
    switch (_normalizeTransportMode(mode)) {
      case 'transit':
        return Icons.directions_transit;
      case 'walking':
      case 'hiking':
      case 'backpacking':
        return Icons.directions_walk;
      case 'portaging':
        return Icons.kayaking;
      case 'biking':
      case 'bikepacking':
        return Icons.directions_bike;
      case 'flying':
        return Icons.flight;
      default:
        return Icons.directions_car;
    }
  }

  String _travelCategoryForMode(String mode) {
    switch (_normalizeTransportMode(mode)) {
      case 'transit':
        return 'Transit';
      case 'walking':
      case 'hiking':
      case 'backpacking':
        return 'Walking';
      case 'portaging':
        return 'Adventure';
      case 'biking':
      case 'bikepacking':
        return 'Biking';
      default:
        return 'Driving';
    }
  }

  String _formatDurationShort(double seconds) {
    if (!seconds.isFinite || seconds <= 0) return '';
    final mins = (seconds / 60).round();
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    if (h > 0) return '${h}h';
    return '${m}m';
  }

  String _formatDistanceShort(double meters) {
    if (!meters.isFinite || meters <= 0) return '';
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  bool _jsonValueEquals(Object? a, Object? b) {
    try {
      return jsonEncode(a) == jsonEncode(b);
    } catch (_) {
      return false;
    }
  }

  String _timeTextTo24Hour(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';

    final hhmm = RegExp(r'^(\\d{1,2}):(\\d{2})$').firstMatch(value);
    if (hhmm != null) {
      final h = int.tryParse(hhmm.group(1)!);
      final m = int.tryParse(hhmm.group(2)!);
      if (h != null && m != null && h >= 0 && h < 24 && m >= 0 && m < 60) {
        return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
      }
    }

    final amPm = RegExp(
      r'(\\d{1,2})(?::(\\d{2}))?\\s*([APap][Mm])',
    ).firstMatch(value);
    if (amPm == null) return '';

    final hRaw = int.tryParse(amPm.group(1)!);
    final mRaw = int.tryParse(amPm.group(2) ?? '0');
    if (hRaw == null || mRaw == null) return '';
    if (hRaw < 1 || hRaw > 12 || mRaw < 0 || mRaw > 59) return '';

    final meridiem = amPm.group(3)!.toLowerCase();
    var hour = hRaw % 12;
    if (meridiem == 'pm') hour += 12;
    return '${hour.toString().padLeft(2, '0')}:${mRaw.toString().padLeft(2, '0')}';
  }

  String _shiftTimeBySeconds(String hhmm, double seconds) {
    final match = RegExp(r'^(\\d{2}):(\\d{2})$').firstMatch(hhmm.trim());
    if (match == null) return '';
    final h = int.tryParse(match.group(1)!);
    final m = int.tryParse(match.group(2)!);
    if (h == null || m == null) return '';
    var totalMinutes = h * 60 + m + (seconds / 60).round();
    totalMinutes %= 24 * 60;
    if (totalMinutes < 0) totalMinutes += 24 * 60;
    final outH = totalMinutes ~/ 60;
    final outM = totalMinutes % 60;
    return '${outH.toString().padLeft(2, '0')}:${outM.toString().padLeft(2, '0')}';
  }

  Map<String, String> _recommendedTravelWindow(
    Map<String, dynamic> recommended,
  ) {
    final departureText =
        (recommended['departureTimeText'] ?? '').toString().trim();
    final arrivalText =
        (recommended['arrivalTimeText'] ?? '').toString().trim();
    final durationSec = _toDouble(recommended['durationSeconds']);

    var start = _timeTextTo24Hour(departureText);
    var end = _timeTextTo24Hour(arrivalText);

    if (start.isEmpty && end.isEmpty && durationSec > 0) {
      start = '09:00';
      end = _shiftTimeBySeconds(start, durationSec);
    } else if (start.isNotEmpty && end.isEmpty && durationSec > 0) {
      end = _shiftTimeBySeconds(start, durationSec);
    } else if (start.isEmpty && end.isNotEmpty && durationSec > 0) {
      start = _shiftTimeBySeconds(end, -durationSec);
    }

    return {'start': start, 'end': end};
  }

  String _recommendedTravelNotes({
    required String mode,
    required Map<String, dynamic> recommended,
  }) {
    final parts = <String>[];
    final summary = (recommended['summary'] ?? '').toString().trim();
    if (summary.isNotEmpty) {
      parts.add('Recommended route: $summary');
    }
    parts.add('Mode: ${_travelModeLabel(mode)}');

    final duration = _formatDurationShort(
      _toDouble(recommended['durationSeconds']),
    );
    if (duration.isNotEmpty) parts.add('Duration: $duration');

    final distance = _formatDistanceShort(
      _toDouble(recommended['distanceMeters']),
    );
    if (distance.isNotEmpty) parts.add('Distance: $distance');

    final transfers = (recommended['transferCount'] as num?)?.toInt() ?? 0;
    if (_normalizeTransportMode(mode) == 'transit') {
      parts.add('Transfers: $transfers');
      final layovers = (recommended['layoverCount'] as num?)?.toInt() ?? 0;
      final layoverMins = _toDouble(recommended['layoverMinutes']);
      parts.add(
        'Layovers: $layovers (${layoverMins > 0 ? layoverMins.round() : 0} min)',
      );
    }

    final departure =
        (recommended['departureTimeText'] ?? '').toString().trim();
    final arrival = (recommended['arrivalTimeText'] ?? '').toString().trim();
    if (departure.isNotEmpty || arrival.isNotEmpty) {
      parts.add(
        'Window: ${departure.isNotEmpty ? departure : '?'} -> ${arrival.isNotEmpty ? arrival : '?'}',
      );
    }

    return parts.join('\n');
  }

  bool _clearTravelRecommendationFields(Map<String, dynamic> day) {
    var changed = false;
    for (final key in const [
      'travelOptions',
      'recommendedTravelOptionIndex',
      'recommendedTravel',
      'travelRecommendationStatus',
      'travelRecommendationUpdatedAt',
      'travelMode',
    ]) {
      if (day.remove(key) != null) changed = true;
    }

    final activities = _mapList(day['activities']);
    final filtered =
        activities.where((a) => a['isAutoTravel'] != true).toList();
    if (filtered.length != activities.length) {
      day['activities'] = _sortActivitiesByStartTime(filtered);
      changed = true;
    }
    return changed;
  }

  bool _upsertAutoTravelActivity({
    required Map<String, dynamic> day,
    required String mode,
    required Map<String, dynamic>? recommended,
  }) {
    final activities = _mapList(day['activities']);
    final existingIndex = activities.indexWhere(
      (a) => a['isAutoTravel'] == true,
    );

    if (recommended == null) {
      if (existingIndex >= 0) {
        activities.removeAt(existingIndex);
        day['activities'] = _sortActivitiesByStartTime(activities);
        return true;
      }
      return false;
    }

    final from = (day['travelFrom'] ?? '').toString();
    final to = (day['travelTo'] ?? '').toString();
    final title =
        (from.isNotEmpty && to.isNotEmpty) ? 'Travel: $from -> $to' : 'Travel';
    final window = _recommendedTravelWindow(recommended);
    final start = (window['start'] ?? '').toString();
    final end = (window['end'] ?? '').toString();

    final activity = <String, dynamic>{
      'title': title,
      'startTime': start,
      'endTime': end,
      'location': [from, to].where((v) => v.trim().isNotEmpty).join(' -> '),
      'notes': _recommendedTravelNotes(mode: mode, recommended: recommended),
      'category': _travelCategoryForMode(mode),
      'isAutoTravel': true,
      'travelMode': mode,
      'travelScore': _toDouble(recommended['score']),
    };

    var changed = false;
    if (existingIndex >= 0) {
      if (!_jsonValueEquals(activities[existingIndex], activity)) {
        activities[existingIndex] = activity;
        changed = true;
      }
    } else {
      activities.insert(0, activity);
      changed = true;
    }

    if (changed) {
      day['activities'] = _sortActivitiesByStartTime(activities);
    }
    return changed;
  }

  double _travelOptionScore(TravelRouteOption option) {
    final durationMins =
        option.durationSeconds > 0 ? option.durationSeconds / 60.0 : 100000.0;
    final transferPenalty = option.transferCount * 18.0;
    final layoverPenalty = option.layoverCount * 12.0 + option.layoverMinutes;
    return durationMins + transferPenalty + layoverPenalty;
  }

  Future<void> _refreshTravelRecommendations({required bool persist}) async {
    final runId = ++_travelRecommendationRunId;
    if (!mounted) return;
    setState(() => _updatingTravelRecommendations = true);

    final days =
        _itineraryDays.map((d) => Map<String, dynamic>.from(d)).toList();
    final waypoints = _mapList(_tripData['waypoints']);
    var changed = false;

    for (var i = 0; i < days.length; i++) {
      final day = days[i];
      final isTravel = day['isTravel'] == true;
      if (!isTravel || (i + 1) >= days.length) {
        if (_clearTravelRecommendationFields(day)) changed = true;
        continue;
      }

      final nextDay = days[i + 1];
      final fromIndex = _resolveWaypointIndexForDay(day, waypoints);
      final toIndex = _resolveWaypointIndexForDay(nextDay, waypoints);
      final coordsFrom = _waypointCoords(waypoints, fromIndex);
      final coordsTo = _waypointCoords(waypoints, toIndex);

      final segmentIndex = _segmentIndexForTravel(
        fromIndex: fromIndex,
        toIndex: toIndex,
        waypointCount: waypoints.length,
      );
      final mode = _segmentTransportModeFor(segmentIndex);

      if ((day['travelMode'] ?? '').toString() != mode) {
        day['travelMode'] = mode;
        changed = true;
      }

      if (coordsFrom == null || coordsTo == null) {
        var localChanged = false;
        if ((day['travelRecommendationStatus'] ?? '').toString() !=
            'unavailable') {
          day['travelRecommendationStatus'] = 'unavailable';
          localChanged = true;
        }
        if (day.remove('travelOptions') != null) localChanged = true;
        if (day.remove('recommendedTravel') != null) localChanged = true;
        if (day.remove('recommendedTravelOptionIndex') != null) {
          localChanged = true;
        }
        if (_upsertAutoTravelActivity(
          day: day,
          mode: mode,
          recommended: null,
        )) {
          localChanged = true;
        }
        if (localChanged) changed = true;
        continue;
      }

      final date = _tryParseDate((day['date'] ?? '').toString());
      final departureTime =
          date == null ? null : DateTime(date.year, date.month, date.day, 8);

      final options = await getRouteOptions(
        originLat: coordsFrom['lat']!,
        originLng: coordsFrom['lon']!,
        destLat: coordsTo['lat']!,
        destLng: coordsTo['lon']!,
        mode: mode,
        departureTime: departureTime,
        avoidHighways: _normalizeTransportMode(mode) == 'biking',
      );

      if (!mounted || runId != _travelRecommendationRunId) return;

      if (options.isEmpty) {
        final previousOptions = _mapList(day['travelOptions']);
        final previousRecommendedRaw = day['recommendedTravel'];
        Map<String, dynamic>? previousRecommended;
        if (previousRecommendedRaw is Map<String, dynamic>) {
          previousRecommended = Map<String, dynamic>.from(
            previousRecommendedRaw,
          );
        } else if (previousRecommendedRaw is Map) {
          previousRecommended = Map<String, dynamic>.from(
            previousRecommendedRaw.cast<String, dynamic>(),
          );
        }

        var localChanged = false;
        if (previousOptions.isNotEmpty && previousRecommended != null) {
          if ((day['travelRecommendationStatus'] ?? '').toString() != 'stale') {
            day['travelRecommendationStatus'] = 'stale';
            localChanged = true;
          }
          if (_upsertAutoTravelActivity(
            day: day,
            mode: mode,
            recommended: previousRecommended,
          )) {
            localChanged = true;
          }
          if (localChanged) changed = true;
          continue;
        }

        if ((day['travelRecommendationStatus'] ?? '').toString() !=
            'unavailable') {
          day['travelRecommendationStatus'] = 'unavailable';
          localChanged = true;
        }
        if (day.remove('travelOptions') != null) localChanged = true;
        if (day.remove('recommendedTravel') != null) localChanged = true;
        if (day.remove('recommendedTravelOptionIndex') != null) {
          localChanged = true;
        }
        if (_upsertAutoTravelActivity(
          day: day,
          mode: mode,
          recommended: null,
        )) {
          localChanged = true;
        }
        if (localChanged) changed = true;
        continue;
      }

      final scored =
          options.asMap().entries.map((entry) {
              final score = _travelOptionScore(entry.value);
              return {
                'sourceIndex': entry.key,
                'score': score,
                'option': entry.value,
              };
            }).toList()
            ..sort(
              (a, b) => (a['score'] as double).compareTo(b['score'] as double),
            );

      final serialized = <Map<String, dynamic>>[];
      for (var rank = 0; rank < scored.length; rank++) {
        final sourceIndex = scored[rank]['sourceIndex'] as int;
        final score = scored[rank]['score'] as double;
        final option = scored[rank]['option'] as TravelRouteOption;
        serialized.add({
          ...option.toMap(),
          'sourceIndex': sourceIndex,
          'score': score,
          'rank': rank + 1,
          'isRecommended': rank == 0,
        });
      }

      final best = Map<String, dynamic>.from(serialized.first);
      final bestSourceIndex = (best['sourceIndex'] as num).toInt();

      var localChanged = false;
      if (!_jsonValueEquals(day['travelOptions'], serialized)) {
        day['travelOptions'] = serialized;
        localChanged = true;
      }
      if ((day['recommendedTravelOptionIndex'] as num?)?.toInt() !=
          bestSourceIndex) {
        day['recommendedTravelOptionIndex'] = bestSourceIndex;
        localChanged = true;
      }
      if (!_jsonValueEquals(day['recommendedTravel'], best)) {
        day['recommendedTravel'] = best;
        localChanged = true;
      }
      if ((day['travelRecommendationStatus'] ?? '').toString() != 'ready') {
        day['travelRecommendationStatus'] = 'ready';
        localChanged = true;
      }
      if (_upsertAutoTravelActivity(day: day, mode: mode, recommended: best)) {
        localChanged = true;
      }
      if (localChanged) {
        day['travelRecommendationUpdatedAt'] = DateTime.now().toIso8601String();
        changed = true;
      }
    }

    if (!mounted || runId != _travelRecommendationRunId) return;

    if (changed) {
      setState(() {
        _itineraryDays = _normalizeItineraryDays(days);
        _syncItineraryControllers();
        if (_itineraryDays.isEmpty) {
          _selectedItineraryDayIndex = 0;
        } else {
          _selectedItineraryDayIndex = _selectedItineraryDayIndex.clamp(
            0,
            _itineraryDays.length - 1,
          );
        }
        _updatingTravelRecommendations = false;
      });

      if (persist) {
        try {
          await FirebaseFirestore.instance.doc(widget.tripRefPath).update({
            'tripItinerary': _itineraryDays,
          });
        } catch (_) {}
      }
      return;
    }

    setState(() => _updatingTravelRecommendations = false);
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
        final previousTransportMode =
            (_tripData['transportMode'] ?? '').toString();
        final previousSegmentModesSig = jsonEncode(
          _tripData['segmentTransportModes'] ?? const [],
        );
        var shouldRefreshRecommendations = false;
        setState(() {
          _tripData = Map<String, dynamic>.from(remote);
          // Re-load only if planning data was updated externally
          // (we compare lengths to avoid overwriting local edits every frame)
          final remoteItin = _tripData['tripItinerary'];
          if (remoteItin is List &&
              remoteItin.length != _itineraryDays.length) {
            _loadPlanningData();
          } else {
            final nextTransportMode =
                (_tripData['transportMode'] ?? '').toString();
            final nextSegmentModesSig = jsonEncode(
              _tripData['segmentTransportModes'] ?? const [],
            );
            shouldRefreshRecommendations =
                nextTransportMode != previousTransportMode ||
                nextSegmentModesSig != previousSegmentModesSig;
          }
        });
        if (shouldRefreshRecommendations && mounted) {
          unawaited(_refreshTravelRecommendations(persist: false));
        }
      });
    } catch (_) {}
  }

  Map<String, dynamic> _planningPayload() {
    return {
      'tripItinerary': _itineraryDays,
      'tripNotes': _notes,
      'tripBudget': {
        'currency': _currency,
        'items': _normalizedBudgetItems(),
        'people': encodeBudgetPeople(_budgetPeople),
        'finalSplitByCount': _resolvedBudgetFinalSplitCount(),
      },
      'tripChecklists': _checklists,
      'tripDocuments': _documents,
      'startDate': (_tripData['startDate'] ?? '').toString(),
      'endDate': (_tripData['endDate'] ?? '').toString(),
      'waypoints': _mapList(_tripData['waypoints']),
    };
  }

  String _planningSignature() {
    final payload = _planningPayload();
    try {
      return jsonEncode(payload);
    } catch (_) {
      return payload.toString();
    }
  }

  Future<bool> _persistPlanning({required bool showFeedback}) async {
    if (showFeedback) {
      if (_saving) return false;
      setState(() => _saving = true);
    } else {
      if (_autoSaveInFlight || _saving) return false;
      _autoSaveInFlight = true;
    }

    try {
      final ref = FirebaseFirestore.instance.doc(widget.tripRefPath);
      await ref.update(_planningPayload());
      _lastPersistedSignature = _planningSignature();

      if (showFeedback && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(const SnackBar(content: Text('Trip plan saved ✓')));
      }
      return true;
    } catch (e) {
      if (showFeedback && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
      return false;
    } finally {
      if (showFeedback) {
        if (mounted) setState(() => _saving = false);
      } else {
        _autoSaveInFlight = false;
      }
    }
  }

  Future<void> _autoSaveTick() async {
    if (_saving || _autoSaveInFlight) return;
    final signature = _planningSignature();
    if (signature == _lastPersistedSignature) return;
    await _persistPlanning(showFeedback: false);
  }

  Future<void> _saveAll() async {
    await _persistPlanning(showFeedback: true);
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
    final safeIndex = dayIndex.clamp(0, _itineraryDays.length - 1);
    _selectedItineraryDayIndex = safeIndex;
    if (!_itineraryScrollController.hasClients) {
      if (mounted) setState(() {});
      return;
    }
    // Rough estimate: each day card ≈ 200px height
    final offset = (safeIndex * 220.0).clamp(
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
  DateTime _stripDate(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  bool _isSameDate(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Future<DateTime?> _pickSinglePlanningDate({
    required DateTime initialDate,
    required DateTime firstDate,
    required DateTime lastDate,
  }) async {
    final safeInitial =
        initialDate.isBefore(firstDate)
            ? firstDate
            : (initialDate.isAfter(lastDate) ? lastDate : initialDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: _stripDate(safeInitial),
      firstDate: _stripDate(firstDate),
      lastDate: _stripDate(lastDate),
    );
    if (picked == null) return null;
    return _stripDate(picked);
  }

  Future<void> _editWaypointStayDates() async {
    final tripStart = _tryParseDate((_tripData['startDate'] ?? '').toString());
    final tripEnd = _tryParseDate((_tripData['endDate'] ?? '').toString());
    if (tripStart == null || tripEnd == null) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Set trip dates first.')),
      );
      return;
    }

    final waypoints = _mapList(_tripData['waypoints']);
    final stayIndexes = <int>[];
    final stayWaypoints = <Map<String, dynamic>>[];
    for (var i = 0; i < waypoints.length; i++) {
      if (!_waypointCountsAsStay(waypoints, i)) continue;
      stayIndexes.add(i);
      stayWaypoints.add(waypoints[i]);
    }
    if (stayWaypoints.isEmpty) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('No stay destinations to edit yet.')),
      );
      return;
    }

    final initialTripStart = _stripDate(tripStart);
    final initialTripEnd = _stripDate(tripEnd);
    final local = <Map<String, dynamic>>[];
    for (var i = 0; i < stayWaypoints.length; i++) {
      final wp = stayWaypoints[i];
      var start =
          _tryParseDate((wp['startDate'] ?? '').toString()) ?? initialTripStart;
      var end = _tryParseDate((wp['endDate'] ?? '').toString()) ?? start;
      start = _stripDate(start);
      end = _stripDate(end);
      if (end.isBefore(start)) end = start;
      local.add({
        'name': (wp['name'] ?? 'Stop ${i + 1}').toString(),
        'start': start,
        'end': end,
      });
    }

    final updatedWaypoints = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (ctx) {
        String validationError = '';
        return StatefulBuilder(
          builder: (ctx2, setState2) {
            Future<void> pickStart(int index) async {
              final currentStart = local[index]['start'] as DateTime;
              final currentEnd = local[index]['end'] as DateTime;
              final picked = await _pickSinglePlanningDate(
                initialDate: currentStart,
                firstDate: initialTripStart,
                lastDate: currentEnd,
              );
              if (picked == null) return;
              setState2(() {
                validationError = '';
                local[index]['start'] = picked;
                if ((local[index]['end'] as DateTime).isBefore(picked)) {
                  local[index]['end'] = picked;
                }
              });
            }

            Future<void> pickEnd(int index) async {
              final currentStart = local[index]['start'] as DateTime;
              final currentEnd = local[index]['end'] as DateTime;
              final picked = await _pickSinglePlanningDate(
                initialDate: currentEnd,
                firstDate: currentStart,
                lastDate: initialTripEnd,
              );
              if (picked == null) return;
              setState2(() {
                validationError = '';
                local[index]['end'] = picked;
              });
            }

            String? validateLocalRanges() {
              for (var i = 0; i < local.length; i++) {
                final start = local[i]['start'] as DateTime;
                final end = local[i]['end'] as DateTime;
                if (end.isBefore(start)) {
                  return 'Each stop must end on or after it starts.';
                }
                if (start.isBefore(initialTripStart) ||
                    end.isAfter(initialTripEnd)) {
                  return 'Stop dates must stay within the trip range.';
                }
              }

              if (!_isSameDate(
                local.first['start'] as DateTime,
                initialTripStart,
              )) {
                return 'The first stop must start on ${_ymd(initialTripStart)}.';
              }

              for (var i = 1; i < local.length; i++) {
                final prevEnd = local[i - 1]['end'] as DateTime;
                final start = local[i]['start'] as DateTime;
                final latestAllowedStart = _stripDate(
                  prevEnd.add(const Duration(days: 1)),
                );
                // Allow overlapping stays (for realistic check-in/check-out),
                // but prevent date gaps between consecutive stops.
                if (start.isAfter(latestAllowedStart)) {
                  return 'Stop ${i + 1} starts too late. It must start on or before ${_ymd(latestAllowedStart)} (overlaps are allowed).';
                }
              }

              if (!_isSameDate(local.last['end'] as DateTime, initialTripEnd)) {
                return 'The last stop must end on ${_ymd(initialTripEnd)}.';
              }

              return null;
            }

            return _overlaySafe(
              AlertDialog(
                title: const Text('Edit stay dates'),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SizedBox(
                    width: 560,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Trip range: ${_ymd(initialTripStart)} → ${_ymd(initialTripEnd)}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: TryprColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 360),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: local.length,
                            separatorBuilder:
                                (_, __) => const SizedBox(height: 10),
                            itemBuilder: (_, i) {
                              final entry = local[i];
                              final start = entry['start'] as DateTime;
                              final end = entry['end'] as DateTime;
                              final nights = end.difference(start).inDays + 1;
                              return Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: TryprColors.textTertiary.withValues(
                                      alpha: 0.25,
                                    ),
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      entry['name'].toString(),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: () => pickStart(i),
                                            icon: const Icon(Icons.event),
                                            label: Text(_ymd(start)),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const Icon(
                                          Icons.arrow_forward,
                                          size: 16,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: () => pickEnd(i),
                                            icon: const Icon(
                                              Icons.event_available,
                                            ),
                                            label: Text(_ymd(end)),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          '$nights night${nights == 1 ? '' : 's'}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: TryprColors.textSecondary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        if (validationError.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              validationError,
                              style: const TextStyle(
                                color: TryprColors.error,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx2).pop(),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () {
                      final error = validateLocalRanges();
                      if (error != null) {
                        setState2(() => validationError = error);
                        return;
                      }
                      final updated = waypoints
                          .map((wp) => Map<String, dynamic>.from(wp))
                          .toList(growable: false);
                      for (var i = 0; i < stayWaypoints.length; i++) {
                        final wpIndex = stayIndexes[i];
                        final wp = Map<String, dynamic>.from(updated[wpIndex]);
                        final start = local[i]['start'] as DateTime;
                        final end = local[i]['end'] as DateTime;
                        wp['startDate'] = _ymd(start);
                        wp['endDate'] = _ymd(end);
                        wp['nights'] = end.difference(start).inDays + 1;
                        updated[wpIndex] = wp;
                      }
                      Navigator.of(ctx2).pop(updated);
                    },
                    child: const Text('Apply'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (updatedWaypoints == null || !mounted) return;

    setState(() {
      _tripData['waypoints'] = updatedWaypoints;
      _tripData['startDate'] =
          (updatedWaypoints.first['startDate'] ?? _tripData['startDate'])
              .toString();
      _tripData['endDate'] =
          (updatedWaypoints.last['endDate'] ?? _tripData['endDate']).toString();
      _itineraryDays = _normalizeItineraryDays(
        _loadOrGenerateItinerary(
          forceRegenerate: true,
          carryFromDays: _itineraryDays,
        ),
      );
      _syncItineraryControllers();
      _selectedItineraryDayIndex =
          _itineraryDays.isEmpty
              ? 0
              : _selectedItineraryDayIndex.clamp(0, _itineraryDays.length - 1);
    });

    await _refreshTravelRecommendations(persist: false);
    await _persistPlanning(showFeedback: true);
  }

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
      _itineraryDays = _normalizeItineraryDays(
        _loadOrGenerateItinerary(
          forceRegenerate: true,
          carryFromDays: _itineraryDays,
        ),
      );
      _syncItineraryControllers();
      _selectedItineraryDayIndex =
          _itineraryDays.isEmpty
              ? 0
              : _selectedItineraryDayIndex.clamp(0, _itineraryDays.length - 1);
    });

    await _refreshTravelRecommendations(persist: false);

    await _persistPlanning(showFeedback: true);
  }

  Widget _buildDateRow() {
    final startStr = (_tripData['startDate'] ?? '').toString();
    final endStr = (_tripData['endDate'] ?? '').toString();
    final waypointCount = _mapList(_tripData['waypoints']).length;

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

    return Column(
      children: [
        GestureDetector(
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
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: waypointCount == 0 ? null : _editWaypointStayDates,
                icon: const Icon(Icons.alt_route, size: 16),
                label: const Text('Edit Stay Dates Per Stop'),
              ),
            ],
          ),
        ),
      ],
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

    final routePoints = _mapRoutePoints();
    final activityPins = _mapItineraryActivityPins();
    final selectedDayIndex = _selectedItineraryDayIndex.clamp(
      0,
      _itineraryDays.length - 1,
    );
    final selectedDay = _itineraryDays[selectedDayIndex];
    final selectedDayNum = (selectedDay['dayNumber'] ?? selectedDayIndex + 1);

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
        if (routePoints.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassCard(
              padding: const EdgeInsets.all(10),
              borderRadius: 14,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.map_outlined, size: 18),
                      const SizedBox(width: 8),
                      const Text(
                        'Itinerary Map',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      Text(
                        '${activityPins.length} activity pin${activityPins.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: TryprColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder: (ctx, box) {
                      final wide = box.maxWidth >= 920;
                      final map = SizedBox(
                        height: 230,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: MapEmbed(
                            points: routePoints,
                            secondaryPoints: activityPins,
                            zoomControlsEnabled: true,
                            onPointTap: _handleItineraryMapPointTap,
                          ),
                        ),
                      );

                      if (wide) {
                        return SizedBox(
                          height: 230,
                          child: Row(
                            children: [
                              Expanded(flex: 7, child: map),
                              const SizedBox(width: 10),
                              Expanded(
                                flex: 5,
                                child: _buildItineraryMapInsightCard(),
                              ),
                            ],
                          ),
                        );
                      }

                      return Column(
                        children: [
                          map,
                          const SizedBox(height: 10),
                          _buildItineraryMapInsightCard(),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: ListView(
            controller: _itineraryScrollController,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
            children: [
              if (routePoints.isNotEmpty) const SizedBox(height: 8),
              _buildItineraryCalendarCard(selectedDayIndex),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    'Day $selectedDayNum Details',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Previous day',
                    icon: const Icon(Icons.chevron_left),
                    onPressed:
                        selectedDayIndex > 0
                            ? () => _selectItineraryDay(selectedDayIndex - 1)
                            : null,
                  ),
                  IconButton(
                    tooltip: 'Next day',
                    icon: const Icon(Icons.chevron_right),
                    onPressed:
                        selectedDayIndex < _itineraryDays.length - 1
                            ? () => _selectItineraryDay(selectedDayIndex + 1)
                            : null,
                  ),
                ],
              ),
              _buildDayCard(selectedDayIndex),
            ],
          ),
        ),
      ],
    );
  }

  void _selectItineraryDay(int dayIndex) {
    if (_itineraryDays.isEmpty) return;
    final safe = dayIndex.clamp(0, _itineraryDays.length - 1);
    if (safe == _selectedItineraryDayIndex) return;
    setState(() => _selectedItineraryDayIndex = safe);
  }

  DateTime? _tryParseDate(String raw) {
    try {
      return DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  Widget _buildItineraryMetricChip({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: TryprColors.surfaceVariant,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: TryprColors.textSecondary),
          const SizedBox(width: 6),
          Text(
            '$value $label',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: TryprColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItineraryCalendarCard(int selectedDayIndex) {
    final firstDate = _tryParseDate(
      (_itineraryDays.first['date'] ?? '').toString(),
    );
    final leadingBlanks = firstDate == null ? 0 : (firstDate.weekday - 1);
    final totalCells = ((leadingBlanks + _itineraryDays.length + 6) ~/ 7) * 7;
    final activityCount = _itineraryDays.fold<int>(
      0,
      (total, d) => total + _mapList(d['activities']).length,
    );
    final travelDays =
        _itineraryDays.where((d) => d['isTravel'] == true).length;
    final plannedDays =
        _itineraryDays
            .where(
              (d) =>
                  _mapList(d['activities']).isNotEmpty ||
                  (d['notes'] ?? '').toString().trim().isNotEmpty,
            )
            .length;

    const weekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return GlassCard(
      padding: const EdgeInsets.all(12),
      borderRadius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Calendar Planner',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildItineraryMetricChip(
                icon: Icons.today,
                value: '${_itineraryDays.length}',
                label: 'days',
              ),
              _buildItineraryMetricChip(
                icon: Icons.local_activity_outlined,
                value: '$activityCount',
                label: 'activities',
              ),
              _buildItineraryMetricChip(
                icon: Icons.alt_route,
                value: '$travelDays',
                label: 'travel days',
              ),
              _buildItineraryMetricChip(
                icon: Icons.check_circle_outline,
                value: '$plannedDays',
                label: 'planned',
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children:
                weekdayLabels
                    .map(
                      (w) => Expanded(
                        child: Center(
                          child: Text(
                            w,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: TryprColors.textTertiary,
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
          ),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: totalCells,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 1.05,
            ),
            itemBuilder: (_, cellIndex) {
              if (cellIndex < leadingBlanks) {
                return const SizedBox.shrink();
              }
              final dayIndex = cellIndex - leadingBlanks;
              if (dayIndex < 0 || dayIndex >= _itineraryDays.length) {
                return const SizedBox.shrink();
              }
              final day = _itineraryDays[dayIndex];
              final selected = dayIndex == selectedDayIndex;
              final isTravel = day['isTravel'] == true;
              final acts = _mapList(day['activities']).length;
              final dayDate = _tryParseDate((day['date'] ?? '').toString());
              final dayOfMonth =
                  dayDate?.day.toString() ??
                  (day['dayNumber'] ?? dayIndex + 1).toString();
              final loc = _shortName((day['locationName'] ?? '').toString());

              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _selectItineraryDay(dayIndex),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color:
                        selected
                            ? TryprColors.primary.withValues(alpha: 0.12)
                            : TryprColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color:
                          selected
                              ? TryprColors.primary
                              : TryprColors.textTertiary.withValues(
                                alpha: 0.25,
                              ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            dayOfMonth,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color:
                                  selected
                                      ? TryprColors.primary
                                      : TryprColors.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          if (isTravel)
                            const Icon(
                              Icons.directions_car,
                              size: 13,
                              color: Colors.orange,
                            ),
                        ],
                      ),
                      Text(
                        'D${day['dayNumber'] ?? dayIndex + 1}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: TryprColors.textTertiary,
                        ),
                      ),
                      const Spacer(),
                      if (!isTravel && loc.isNotEmpty)
                        Text(
                          loc,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10,
                            color: TryprColors.textSecondary,
                          ),
                        ),
                      if (acts > 0)
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: TryprColors.secondary.withValues(
                              alpha: 0.16,
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '$acts',
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: TryprColors.secondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDayCard(int dayIndex) {
    final day = _itineraryDays[dayIndex];
    final dateStr = (day['date'] ?? '').toString();
    final dayNum = (day['dayNumber'] ?? dayIndex + 1);
    final location = (day['locationName'] ?? '').toString();
    final activities = _sortActivitiesByStartTime(_mapList(day['activities']));
    final isTravel = day['isTravel'] == true;
    final travelFrom = (day['travelFrom'] ?? '').toString();
    final travelTo = (day['travelTo'] ?? '').toString();
    final travelMode = (day['travelMode'] ?? '').toString();
    final recommendationStatus =
        (day['travelRecommendationStatus'] ?? '').toString();
    final travelOptions = _mapList(day['travelOptions']);
    final recommendedSourceIndex =
        (day['recommendedTravelOptionIndex'] as num?)?.toInt() ?? -1;
    final titleCtrl = _dayTitleControllerFor(dayIndex);
    final notesCtrl = _dayNotesControllerFor(dayIndex);

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
          if (isTravel) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: TryprColors.surfaceVariant,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: TryprColors.textTertiary.withValues(alpha: 0.25),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _travelModeIcon(travelMode),
                        size: 15,
                        color: TryprColors.textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${_travelModeLabel(travelMode)} options',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      if (_updatingTravelRecommendations)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (travelOptions.isEmpty)
                    Text(
                      _updatingTravelRecommendations
                          ? 'Calculating best travel options...'
                          : recommendationStatus == 'unavailable'
                          ? 'No live route options found for this segment yet.'
                          : 'No travel recommendation yet.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: TryprColors.textTertiary,
                      ),
                    ),
                  if (travelOptions.isNotEmpty)
                    ...travelOptions.take(3).map((opt) {
                      final sourceIndex =
                          (opt['sourceIndex'] as num?)?.toInt() ?? -1;
                      final recommended =
                          sourceIndex == recommendedSourceIndex ||
                          opt['isRecommended'] == true;
                      final duration = _formatDurationShort(
                        _toDouble(opt['durationSeconds']),
                      );
                      final transfers =
                          (opt['transferCount'] as num?)?.toInt() ?? 0;
                      final layovers =
                          (opt['layoverCount'] as num?)?.toInt() ?? 0;
                      final departure =
                          (opt['departureTimeText'] ?? '').toString().trim();
                      final arrival =
                          (opt['arrivalTimeText'] ?? '').toString().trim();

                      return Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color:
                              recommended
                                  ? TryprColors.primary.withValues(alpha: 0.1)
                                  : Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color:
                                recommended
                                    ? TryprColors.primary.withValues(
                                      alpha: 0.45,
                                    )
                                    : TryprColors.textTertiary.withValues(
                                      alpha: 0.2,
                                    ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    (opt['summary'] ?? 'Route option')
                                        .toString(),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (recommended)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: TryprColors.primary.withValues(
                                        alpha: 0.12,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: const Text(
                                      'Best',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: TryprColors.primary,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                if (duration.isNotEmpty)
                                  Text(
                                    duration,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: TryprColors.textSecondary,
                                    ),
                                  ),
                                if (_normalizeTransportMode(travelMode) ==
                                    'transit')
                                  Text(
                                    '$transfers transfer${transfers == 1 ? '' : 's'}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: TryprColors.textSecondary,
                                    ),
                                  ),
                                if (_normalizeTransportMode(travelMode) ==
                                        'transit' &&
                                    layovers > 0)
                                  Text(
                                    '$layovers layover${layovers == 1 ? '' : 's'}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: TryprColors.textSecondary,
                                    ),
                                  ),
                                if (departure.isNotEmpty || arrival.isNotEmpty)
                                  Text(
                                    '${departure.isNotEmpty ? departure : '?'} -> ${arrival.isNotEmpty ? arrival : '?'}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: TryprColors.textSecondary,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ],

          const SizedBox(height: 8),
          // ── Editable title ──
          TextField(
            controller: titleCtrl,
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
            controller: notesCtrl,
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
                (ctx, setD) => _overlaySafe(
                  AlertDialog(
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
                                  child: _timeTile(ctx, 'Start', startTime, (
                                    t,
                                  ) {
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
                                constraints: const BoxConstraints(
                                  maxHeight: 150,
                                ),
                                margin: const EdgeInsets.only(top: 4),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.grey.shade300,
                                  ),
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
                                  (v) =>
                                      setD(() => category = v ?? 'Exploring'),
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
                        onPressed: () async {
                          locDebounce?.cancel();
                          if (titleCtrl.text.trim().isEmpty) {
                            ScaffoldMessenger.of(ctx).showTryprSnackBar(
                              const SnackBar(
                                content: Text('Please enter an activity title'),
                              ),
                            );
                            return;
                          }
                          final locationText = locationCtrl.text.trim();
                          var resolvedLat = locationLat;
                          var resolvedLon = locationLon;

                          if (locationText.isNotEmpty &&
                              (resolvedLat == null || resolvedLon == null)) {
                            try {
                              final results = await AddressSearchService.search(
                                locationText,
                              );
                              if (results.isNotEmpty) {
                                resolvedLat = results.first.lat;
                                resolvedLon = results.first.lon;
                              }
                            } catch (_) {}
                          }

                          final activity = <String, dynamic>{
                            'title': titleCtrl.text.trim(),
                            'startTime': startTime,
                            'endTime': endTime,
                            'location': locationText,
                            'notes': notesCtrl.text.trim(),
                            'category': category,
                            if (resolvedLat != null) 'locationLat': resolvedLat,
                            if (resolvedLon != null) 'locationLon': resolvedLon,
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
                            _itineraryDays[dayIndex]['activities'] =
                                _sortActivitiesByStartTime(acts);
                          });
                          if (!mounted) return;
                          Navigator.of(context).pop();
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
                      'contentDelta': null,
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
                                        _syncNoteControllers();
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
    final editorController = _noteContentQuillCtrl;

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
                    onPressed: () {
                      setState(() {
                        _selectedNoteIndex = null;
                        _syncNoteControllers();
                      });
                    },
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
                    onChanged: (v) {
                      _notes[_selectedNoteIndex!]['title'] = v;
                      _notes[_selectedNoteIndex!]['updatedAt'] =
                          DateTime.now().toIso8601String();
                    },
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
                            _notes[_selectedNoteIndex!]['updatedAt'] =
                                DateTime.now().toIso8601String();
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
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
              ),
              child:
                  editorController == null
                      ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : Column(
                        children: [
                          quill.QuillSimpleToolbar(
                            controller: editorController,
                            config: quill.QuillSimpleToolbarConfig(
                              multiRowsDisplay: false,
                              showFontFamily: false,
                              showFontSize: false,
                              showSmallButton: false,
                              showColorButton: false,
                              showBackgroundColorButton: false,
                              showAlignmentButtons: false,
                              showSubscript: false,
                              showSuperscript: false,
                              showInlineCode: false,
                              showCodeBlock: false,
                              showQuote: false,
                              showIndent: false,
                              showSearchButton: false,
                              showDirection: false,
                              showClipboardCut: true,
                              showClipboardCopy: true,
                              showClipboardPaste: true,
                              embedButtons: FlutterQuillEmbeds.toolbarButtons(
                                imageButtonOptions:
                                    QuillToolbarImageButtonOptions(
                                      imageButtonConfig:
                                          QuillToolbarImageConfig(
                                            onRequestPickImage:
                                                (_) =>
                                                    _pickAndUploadNoteImage(),
                                          ),
                                    ),
                                videoButtonOptions: null,
                                cameraButtonOptions: null,
                              ),
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: quill.QuillEditor(
                                controller: editorController,
                                focusNode: _noteEditorFocus,
                                scrollController: _noteEditorScroll,
                                config: quill.QuillEditorConfig(
                                  placeholder:
                                      'Write your notes here (supports bold, italics, lists, and images)…',
                                  embedBuilders:
                                      FlutterQuillEmbeds.defaultEditorBuilders(),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Tip: paste images directly from clipboard when supported by your browser/device.',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.black.withValues(alpha: 0.55),
                ),
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
      _bindNoteEditorForSelection();
      return;
    }
    _noteTitleCtrl.clear();
    _bindNoteEditorForSelection();
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GlassCard(
            padding: const EdgeInsets.all(12),
            borderRadius: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'People',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_budgetPeople.length} saved',
                      style: const TextStyle(
                        fontSize: 12,
                        color: TryprColors.textTertiary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Create people here, then assign who paid. The final split is calculated once in the summary at the end.',
                  style: TextStyle(
                    fontSize: 12,
                    color: TryprColors.textTertiary,
                  ),
                ),
                const SizedBox(height: 10),
                if (_budgetPeople.isEmpty)
                  const Text(
                    'No people added yet.',
                    style: TextStyle(
                      fontSize: 12,
                      color: TryprColors.textTertiary,
                    ),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children:
                        _budgetPeople
                            .map(
                              (person) => InputChip(
                                label: Text(person.name),
                                onDeleted:
                                    () => setState(
                                      () => _budgetPeople.removeWhere(
                                        (entry) => entry.id == person.id,
                                      ),
                                    ),
                              ),
                            )
                            .toList(),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _budgetPersonCtrl,
                        decoration: const InputDecoration(
                          hintText: 'Add a person',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _addBudgetPerson(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GradientButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      onPressed: _addBudgetPerson,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.person_add_alt_1, size: 16),
                          SizedBox(width: 6),
                          Text('Add Person'),
                        ],
                      ),
                    ),
                  ],
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
                    itemCount: _budgetItems.length + 1,
                    itemBuilder: (ctx, i) {
                      if (i == _budgetItems.length) {
                        return _buildBudgetFinalSummary(
                          totalEstimated: totalEstimated,
                          totalActual: totalActual,
                        );
                      }
                      return _buildBudgetRow(i);
                    },
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
    final itemPeople = _budgetPeopleForItem(item);
    final paidById = (item['paidByPersonId'] ?? '').toString().trim();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(10),
        borderRadius: 10,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
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
                TextButton.icon(
                  onPressed: () => setState(() => _budgetItems.removeAt(index)),
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: TryprColors.error,
                  ),
                  label: const Text(
                    'Delete',
                    style: TextStyle(color: TryprColors.error),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 180,
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        budgetCategories.contains(item['category']?.toString())
                            ? item['category'].toString()
                            : 'Other',
                    decoration: const InputDecoration(
                      labelText: 'Category',
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
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<String?>(
                    initialValue: paidById.isEmpty ? null : paidById,
                    decoration: const InputDecoration(
                      labelText: 'Paid by',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Unassigned'),
                      ),
                      ...itemPeople.map(
                        (person) => DropdownMenuItem<String?>(
                          value: person.id,
                          child: Text(person.name),
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      final nextId = (value ?? '').trim();
                      final person = budgetPersonById(itemPeople, nextId);
                      setState(() {
                        if (nextId.isEmpty) {
                          _budgetItems[index].remove('paidByPersonId');
                          _budgetItems[index].remove('paidByPersonName');
                        } else {
                          _budgetItems[index]['paidByPersonId'] = nextId;
                          _budgetItems[index]['paidByPersonName'] =
                              person?.name ?? '';
                        }
                      });
                    },
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: TextEditingController(
                        text: _numStr(item['estimated']),
                      )
                      ..selection = TextSelection.collapsed(
                        offset: _numStr(item['estimated']).length,
                      ),
                    decoration: const InputDecoration(
                      labelText: 'Estimated',
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
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: TextEditingController(
                        text: _numStr(item['actual']),
                      )
                      ..selection = TextSelection.collapsed(
                        offset: _numStr(item['actual']).length,
                      ),
                    decoration: const InputDecoration(
                      labelText: 'Actual',
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
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
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

  Widget _buildBudgetFinalSummary({
    required double totalEstimated,
    required double totalActual,
  }) {
    final splitByCount = _resolvedBudgetFinalSplitCount();
    final currencySymbol = _currencySymbol(_currency);
    final eachEstimated =
        splitByCount <= 0 ? 0.0 : totalEstimated / splitByCount;
    final eachActual = splitByCount <= 0 ? 0.0 : totalActual / splitByCount;

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        borderRadius: 10,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Final summary',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Apply the split once here after all expenses are entered.',
              style: TextStyle(fontSize: 12, color: TryprColors.textTertiary),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Text(
                  'Split total by',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 10),
                IconButton(
                  onPressed:
                      splitByCount <= 1
                          ? null
                          : () => setState(
                            () => _budgetFinalSplitByCount = splitByCount - 1,
                          ),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                Container(
                  constraints: const BoxConstraints(minWidth: 44),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0x14000000)),
                  ),
                  child: Text(
                    '$splitByCount',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  onPressed:
                      () => setState(
                        () => _budgetFinalSplitByCount = splitByCount + 1,
                      ),
                  icon: const Icon(Icons.add_circle_outline),
                ),
                const Spacer(),
                Text(
                  '${_budgetPeople.length} people saved',
                  style: const TextStyle(
                    fontSize: 12,
                    color: TryprColors.textTertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _budgetSummaryPill(
                  label: 'Each estimated',
                  value: '$currencySymbol${eachEstimated.toStringAsFixed(2)}',
                ),
                _budgetSummaryPill(
                  label: 'Each actual',
                  value: '$currencySymbol${eachActual.toStringAsFixed(2)}',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _budgetSummaryPill({required String label, required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x12000000)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: TryprColors.textTertiary,
            ),
          ),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  String _numStr(dynamic n) {
    if (n == null) return '';
    if (n is num) {
      return n == 0 ? '' : n.toStringAsFixed(n == n.roundToDouble() ? 0 : 2);
    }
    return n.toString();
  }

  void _addBudgetPerson() {
    final name = _budgetPersonCtrl.text.trim();
    if (name.isEmpty) return;

    final exists = _budgetPeople.any(
      (person) => person.name.trim().toLowerCase() == name.toLowerCase(),
    );
    if (exists) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('That person already exists')),
      );
      return;
    }

    setState(() {
      _budgetPeople = <BudgetPerson>[
        ..._budgetPeople,
        BudgetPerson.custom(name),
      ];
      _budgetPersonCtrl.clear();
    });
  }

  List<Map<String, dynamic>> _normalizedBudgetItems() {
    return _budgetItems
        .map((rawItem) {
          final item = Map<String, dynamic>.from(rawItem);
          final paidById = (item['paidByPersonId'] ?? '').toString().trim();
          final fallbackName =
              (item['paidByPersonName'] ?? '').toString().trim();
          final paidBy = budgetPersonById(_budgetPeople, paidById);

          item['id'] =
              (item['id'] ?? '').toString().trim().isNotEmpty
                  ? item['id'].toString().trim()
                  : _newId();
          item['description'] = (item['description'] ?? '').toString();
          item['category'] = (item['category'] ?? 'Other').toString();
          item['estimated'] = (item['estimated'] as num?)?.toDouble() ?? 0.0;
          item['actual'] = (item['actual'] as num?)?.toDouble() ?? 0.0;
          item['notes'] = (item['notes'] ?? '').toString();
          item.remove('splitByCount');

          if (paidById.isEmpty) {
            item.remove('paidByPersonId');
            item.remove('paidByPersonName');
          } else {
            item['paidByPersonId'] = paidById;
            item['paidByPersonName'] = paidBy?.name ?? fallbackName;
          }

          return item;
        })
        .toList(growable: false);
  }

  int _parseBudgetFinalSplitCount(dynamic raw) {
    if (raw is int && raw > 0) return raw;
    if (raw is num && raw > 0) return raw.round();
    final parsed = int.tryParse(raw?.toString() ?? '');
    if (parsed == null || parsed <= 0) return 0;
    return parsed;
  }

  int _resolvedBudgetFinalSplitCount() {
    if (_budgetFinalSplitByCount > 0) return _budgetFinalSplitByCount;
    if (_budgetPeople.isNotEmpty) return _budgetPeople.length;
    return 1;
  }

  List<BudgetPerson> _budgetPeopleForItem(Map<String, dynamic> item) {
    final selectedId = (item['paidByPersonId'] ?? '').toString().trim();
    final fallbackName = (item['paidByPersonName'] ?? '').toString().trim();
    if (selectedId.isEmpty ||
        budgetPersonById(_budgetPeople, selectedId) != null) {
      return _budgetPeople;
    }
    return <BudgetPerson>[
      ..._budgetPeople,
      BudgetPerson.custom(
        fallbackName.isNotEmpty ? fallbackName : selectedId,
        id: selectedId,
      ),
    ];
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

  ({Uint8List bytes, String contentType})? _decodeDataUrl(String dataUrl) {
    final raw = dataUrl.trim();
    if (!raw.startsWith('data:')) return null;
    final comma = raw.indexOf(',');
    if (comma <= 0) return null;

    final header = raw.substring(0, comma);
    final payload = raw.substring(comma + 1);

    String contentType = 'application/octet-stream';
    if (header.startsWith('data:')) {
      final meta = header.substring(5);
      final parts = meta.split(';');
      if (parts.isNotEmpty && parts.first.trim().isNotEmpty) {
        contentType = parts.first.trim();
      }
    }

    try {
      return (bytes: base64Decode(payload), contentType: contentType);
    } catch (_) {
      return null;
    }
  }

  String _sanitizeFileName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 'document.bin';
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  String _guessImageContentType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    return 'image/jpeg';
  }

  Future<String?> _uploadNoteImageFromBytes({
    required Uint8List bytes,
    required String contentType,
    required String fileName,
  }) async {
    final safeName = _sanitizeFileName(fileName);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final storagePath = 'tripNotes/${widget.tripId}/${ts}_$safeName';
    final ref = FirebaseStorage.instance.ref(storagePath);
    final task = await ref.putData(
      bytes,
      SettableMetadata(
        contentType: contentType,
        customMetadata: {
          'tripId': widget.tripId,
          'originalName': fileName,
          'source': 'tripNotes',
        },
      ),
    );
    return task.ref.getDownloadURL();
  }

  Future<String?> _pickAndUploadNoteImage() async {
    try {
      if (kIsWeb) {
        final picked = await pickFileDataUrl(
          accept: '.png,.jpg,.jpeg,.webp,.gif,.bmp',
        );
        if (picked == null) return null;
        final decoded = _decodeDataUrl(picked.dataUrl);
        if (decoded == null || !decoded.contentType.startsWith('image/')) {
          if (mounted) {
            ScaffoldMessenger.of(context).showTryprSnackBar(
              const SnackBar(
                content: Text('Please choose a valid image file.'),
              ),
            );
          }
          return null;
        }
        return _uploadNoteImageFromBytes(
          bytes: decoded.bytes,
          contentType: decoded.contentType,
          fileName: picked.fileName,
        );
      }

      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return null;
      final bytes = await picked.readAsBytes();
      final contentType =
          (picked.mimeType?.trim().isNotEmpty ?? false)
              ? picked.mimeType!.trim()
              : _guessImageContentType(picked.name);
      return _uploadNoteImageFromBytes(
        bytes: bytes,
        contentType: contentType,
        fileName: picked.name,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(
            content: Text('Image upload failed. Please try again.'),
          ),
        );
      }
      return null;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024.0;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024.0;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024.0;
    return '${gb.toStringAsFixed(2)} GB';
  }

  Map<String, dynamic>? _normalizedDocumentAttachment(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw.cast<String, dynamic>());
    final url = (map['url'] ?? '').toString().trim();
    if (url.isEmpty) return null;
    return map;
  }

  List<Map<String, dynamic>> _documentAttachmentsFor(Map<String, dynamic> doc) {
    final attachments = <Map<String, dynamic>>[];
    final seen = <String>{};

    final rawList = doc['attachments'];
    if (rawList is List) {
      for (final raw in rawList) {
        final attachment = _normalizedDocumentAttachment(raw);
        if (attachment == null) continue;
        final url = (attachment['url'] ?? '').toString().trim();
        if (!seen.add(url)) continue;
        attachments.add(attachment);
      }
    }

    final legacy = _normalizedDocumentAttachment(doc['attachment']);
    if (legacy != null) {
      final url = (legacy['url'] ?? '').toString().trim();
      if (seen.add(url)) {
        attachments.add(legacy);
      }
    }

    return attachments;
  }

  Future<Map<String, dynamic>?> _uploadDocumentAttachment() async {
    if (!kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(
            content: Text(
              'Document upload is currently available on web only.',
            ),
          ),
        );
      }
      return null;
    }

    final picked = await pickFileDataUrl(
      accept: '.pdf,.png,.jpg,.jpeg,.webp,.txt,.doc,.docx,.xls,.xlsx,.csv,.rtf',
    );
    if (picked == null) return null;

    final decoded = _decodeDataUrl(picked.dataUrl);
    if (decoded == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(content: Text('Unsupported file format selected.')),
        );
      }
      return null;
    }

    final safeName = _sanitizeFileName(picked.fileName);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final storagePath = 'tripDocuments/${widget.tripId}/${ts}_$safeName';
    final ref = FirebaseStorage.instance.ref(storagePath);
    final meta = SettableMetadata(
      contentType: decoded.contentType,
      customMetadata: {
        'tripId': widget.tripId,
        'originalName': picked.fileName,
      },
    );

    final task = await ref.putData(decoded.bytes, meta);
    final url = await task.ref.getDownloadURL();
    return {
      'fileName': picked.fileName,
      'url': url,
      'contentType': decoded.contentType,
      'sizeBytes': decoded.bytes.length,
      'storagePath': storagePath,
      'uploadedAt': DateTime.now().toIso8601String(),
    };
  }

  Future<void> _copyToClipboard(String value, String successMessage) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text(successMessage)));
      }
    } catch (_) {}
  }

  Future<void> _openAttachmentUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;

    try {
      final opened = await openExternalUrl(trimmed, sameTab: true);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(content: Text('Could not open this attachment.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(content: Text('Could not open this attachment.')),
        );
      }
    }
  }

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
    final attachments = _documentAttachmentsFor(doc);

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
            if (attachments.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: TryprColors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: TryprColors.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.attach_file, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            attachments.length == 1
                                ? '1 attachment'
                                : '${attachments.length} attachments',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (final entry in attachments.asMap().entries) ...[
                      if (entry.key > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Divider(
                            height: 1,
                            color: TryprColors.primary.withValues(alpha: 0.14),
                          ),
                        ),
                      Builder(
                        builder: (context) {
                          final attachment = entry.value;
                          final attachmentUrl =
                              (attachment['url'] ?? '').toString();
                          final attachmentName =
                              (attachment['fileName'] ?? 'Attachment')
                                  .toString();
                          final attachmentSize =
                              (attachment['sizeBytes'] as num?)?.toInt() ?? 0;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      attachmentName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _formatBytes(attachmentSize),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: TryprColors.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  TextButton.icon(
                                    onPressed:
                                        () => _openAttachmentUrl(attachmentUrl),
                                    icon: const Icon(
                                      Icons.open_in_new,
                                      size: 14,
                                    ),
                                    label: const Text('Open'),
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed:
                                        () => _copyToClipboard(
                                          attachmentUrl,
                                          'Attachment link copied',
                                        ),
                                    icon: const Icon(Icons.link, size: 14),
                                    label: const Text('Copy link'),
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ],
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
    List<Map<String, dynamic>> attachments =
        existing == null
            ? <Map<String, dynamic>>[]
            : _documentAttachmentsFor(existing);
    bool uploading = false;

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
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: TryprColors.textTertiary.withValues(
                                alpha: 0.25,
                              ),
                            ),
                            color: TryprColors.surfaceVariant,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                attachments.length == 1
                                    ? 'Attachment'
                                    : 'Attachments',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              if (attachments.isNotEmpty)
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxHeight: 160,
                                  ),
                                  child: ListView.separated(
                                    shrinkWrap: true,
                                    itemCount: attachments.length,
                                    separatorBuilder:
                                        (_, __) => const SizedBox(height: 6),
                                    itemBuilder: (context, attachmentIndex) {
                                      final attachment =
                                          attachments[attachmentIndex];
                                      final fileName =
                                          (attachment['fileName'] ??
                                                  'Attachment')
                                              .toString();
                                      final sizeBytes =
                                          (attachment['sizeBytes'] as num?)
                                              ?.toInt() ??
                                          0;
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: TryprColors.textTertiary
                                                .withValues(alpha: 0.16),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.attach_file,
                                              size: 15,
                                            ),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    fileName,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                  Text(
                                                    _formatBytes(sizeBytes),
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color:
                                                          TryprColors
                                                              .textTertiary,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.close,
                                                size: 16,
                                              ),
                                              visualDensity:
                                                  VisualDensity.compact,
                                              onPressed:
                                                  () => setD(
                                                    () => attachments.removeAt(
                                                      attachmentIndex,
                                                    ),
                                                  ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                )
                              else
                                const Text(
                                  'No files attached',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: TryprColors.textTertiary,
                                  ),
                                ),
                              const SizedBox(height: 6),
                              OutlinedButton.icon(
                                onPressed:
                                    uploading
                                        ? null
                                        : () async {
                                          setD(() => uploading = true);
                                          try {
                                            final uploaded =
                                                await _uploadDocumentAttachment();
                                            if (uploaded != null) {
                                              setD(
                                                () =>
                                                    attachments = [
                                                      ...attachments,
                                                      uploaded,
                                                    ],
                                              );
                                            }
                                          } catch (e) {
                                            if (!ctx.mounted) return;
                                            ScaffoldMessenger.of(
                                              ctx,
                                            ).showTryprSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  'Upload failed: $e',
                                                ),
                                              ),
                                            );
                                          } finally {
                                            if (mounted) {
                                              setD(() => uploading = false);
                                            }
                                          }
                                        },
                                icon:
                                    uploading
                                        ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                        : const Icon(Icons.upload_file),
                                label: Text(
                                  uploading
                                      ? 'Uploading…'
                                      : attachments.isEmpty
                                      ? 'Upload file'
                                      : 'Add another file',
                                ),
                              ),
                            ],
                          ),
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
                          ScaffoldMessenger.of(ctx).showTryprSnackBar(
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
                          if (attachments.isNotEmpty) ...{
                            'attachments': attachments,
                            'attachment': attachments.first,
                          },
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
