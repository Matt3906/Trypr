import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:trypr/services/ai_suggestions.dart';
import 'package:trypr/widgets/modern_widgets.dart';
import 'package:trypr/widgets/premium_upsell_dialog.dart';

enum ActivityFinderMode { activities, routeStop }

enum ActivityType {
  adventure,
  foodDrink,
  cultureMuseum,
  relaxation,
  sightseeing,
  nightlife,
  towns,
  attractions,
}

enum RouteStayType { hotel, hostel, camping }

enum BudgetTier { budget, moderate, luxury }

enum TimeAvailable { oneToTwoHours, halfDay, fullDay }

String _labelForType(ActivityType t) {
  switch (t) {
    case ActivityType.adventure:
      return 'Adventure';
    case ActivityType.foodDrink:
      return 'Food & Drink';
    case ActivityType.cultureMuseum:
      return 'Culture/Museum';
    case ActivityType.relaxation:
      return 'Relaxation';
    case ActivityType.sightseeing:
      return 'Sightseeing';
    case ActivityType.nightlife:
      return 'Nightlife';
    case ActivityType.towns:
      return 'Towns';
    case ActivityType.attractions:
      return 'Attractions';
  }
}

IconData _iconForType(ActivityType t) {
  switch (t) {
    case ActivityType.adventure:
      return Icons.terrain;
    case ActivityType.foodDrink:
      return Icons.restaurant;
    case ActivityType.cultureMuseum:
      return Icons.museum;
    case ActivityType.relaxation:
      return Icons.spa;
    case ActivityType.sightseeing:
      return Icons.camera_alt;
    case ActivityType.nightlife:
      return Icons.nightlife;
    case ActivityType.towns:
      return Icons.location_city;
    case ActivityType.attractions:
      return Icons.attractions;
  }
}

String _labelForRouteStayType(RouteStayType t) {
  switch (t) {
    case RouteStayType.hotel:
      return 'Hotel';
    case RouteStayType.hostel:
      return 'Hostel';
    case RouteStayType.camping:
      return 'Camping';
  }
}

IconData _iconForRouteStayType(RouteStayType t) {
  switch (t) {
    case RouteStayType.hotel:
      return Icons.hotel;
    case RouteStayType.hostel:
      return Icons.bed;
    case RouteStayType.camping:
      return Icons.forest;
  }
}

String _normalizeRouteMode(String? raw) {
  var value = (raw ?? '').trim().toLowerCase();
  if (value == 'canoe' || value == 'canoeing' || value == 'portage') {
    value = 'portaging';
  }
  if (value == 'walking') value = 'walk';
  if (value == 'bicycling' || value == 'biking' || value == 'bikepacking') {
    value = 'bike';
  }
  if (value == 'backpacking') value = 'hiking';
  return value.isEmpty ? 'car' : value;
}

RouteStayType _defaultRouteStayTypeForMode(String? rawMode) {
  switch (_normalizeRouteMode(rawMode)) {
    case 'hiking':
    case 'portaging':
      return RouteStayType.camping;
    case 'bike':
      return RouteStayType.hostel;
    default:
      return RouteStayType.hotel;
  }
}

BudgetTier _defaultBudgetForRouteMode(String? rawMode) {
  switch (_normalizeRouteMode(rawMode)) {
    case 'hiking':
    case 'portaging':
      return BudgetTier.budget;
    default:
      return BudgetTier.moderate;
  }
}

String _routeModeRecommendation(String? rawMode) {
  switch (_normalizeRouteMode(rawMode)) {
    case 'hiking':
      return 'Camping is the default for hiking legs so suggestions stay trail-friendly.';
    case 'portaging':
      return 'Camping is the default for portage legs so suggestions bias toward backcountry-style stops.';
    case 'bike':
      return 'Hostels are the default for bike legs so quick route-stop suggestions stay lightweight.';
    default:
      return 'Hotel is the default for road-style legs, but you can switch the stay type any time.';
  }
}

String _labelForBudget(BudgetTier b) {
  switch (b) {
    case BudgetTier.budget:
      return r'Budget ($)';
    case BudgetTier.moderate:
      return r'Moderate ($$)';
    case BudgetTier.luxury:
      return r'Luxury ($$$)';
  }
}

String _labelForTime(TimeAvailable t) {
  switch (t) {
    case TimeAvailable.oneToTwoHours:
      return '1-2 Hours';
    case TimeAvailable.halfDay:
      return 'Half Day (4 hrs)';
    case TimeAvailable.fullDay:
      return 'Full Day (8+ hrs)';
  }
}

Map<String, dynamic> _buildPreferences({
  required ActivityFinderMode mode,
  required ActivityType type,
  required BudgetTier budget,
  required int groupSize,
  required TimeAvailable timeAvailable,
  required bool haveCar,
  RouteStayType? routeStayType,
  String? routeFromName,
  String? routeToName,
  String? routeMode,
}) {
  final out = <String, dynamic>{
    'mode': mode.name,
    'activityType': type.name,
    'budgetTier': budget.name,
    'groupSize': groupSize,
    'timeAvailable': timeAvailable.name,
    'haveCar': haveCar,
  };
  if (mode == ActivityFinderMode.routeStop) {
    out['stayType'] = (routeStayType ?? RouteStayType.hotel).name;
    out['routeIntent'] = 'between_stops';
    out['scope'] = 'along_route';
    out['maxTravelMinutes'] = 30;
    out['routeMode'] = _normalizeRouteMode(routeMode);
    final from = (routeFromName ?? '').trim();
    final to = (routeToName ?? '').trim();
    if (from.isNotEmpty) out['routeFrom'] = from;
    if (to.isNotEmpty) out['routeTo'] = to;
  }
  return out;
}

Future<void> showActivityFinderModal(
  BuildContext context, {
  required ActivityFinderMode mode,
  required String destinationName,
  required double lat,
  required double lon,
  required String startDate,
  required String endDate,
  required int dayCount,
  required Future<void> Function(int dayIndex, Map<String, dynamic> suggestion)
  onAddToItinerary,
  String title = 'Find Things to Do',
}) async {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return _ActivityFinderSheet(
        mode: mode,
        title: title,
        destinationName: destinationName,
        lat: lat,
        lon: lon,
        startDate: startDate,
        endDate: endDate,
        dayCount: dayCount,
        onAddToItinerary: onAddToItinerary,
      );
    },
  );
}

Future<void> showSmartRouteModal(
  BuildContext context, {
  required String title,
  required String destinationName,
  required double lat,
  required double lon,
  required String startDate,
  required String endDate,
  required Future<void> Function(Map<String, dynamic> suggestion) onAddStop,
  String? routeFromName,
  String? routeToName,
  String? routeMode,
}) async {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return _ActivityFinderSheet(
        mode: ActivityFinderMode.routeStop,
        title: title,
        destinationName: destinationName,
        lat: lat,
        lon: lon,
        startDate: startDate,
        endDate: endDate,
        dayCount: 0,
        onAddToItinerary: (_, __) async {},
        onAddStop: onAddStop,
        routeFromName: routeFromName,
        routeToName: routeToName,
        routeMode: routeMode,
      );
    },
  );
}

class _ActivityFinderSheet extends StatefulWidget {
  final ActivityFinderMode mode;
  final String title;
  final String destinationName;
  final double lat;
  final double lon;
  final String startDate;
  final String endDate;
  final int dayCount;
  final Future<void> Function(int dayIndex, Map<String, dynamic> suggestion)
  onAddToItinerary;
  final Future<void> Function(Map<String, dynamic> suggestion)? onAddStop;
  final String? routeFromName;
  final String? routeToName;
  final String? routeMode;

  const _ActivityFinderSheet({
    required this.mode,
    required this.title,
    required this.destinationName,
    required this.lat,
    required this.lon,
    required this.startDate,
    required this.endDate,
    required this.dayCount,
    required this.onAddToItinerary,
    this.onAddStop,
    this.routeFromName,
    this.routeToName,
    this.routeMode,
  });

  @override
  State<_ActivityFinderSheet> createState() => _ActivityFinderSheetState();
}

class _ActivityFinderSheetState extends State<_ActivityFinderSheet> {
  ActivityType _type = ActivityType.adventure;
  RouteStayType _routeStayType = RouteStayType.hotel;
  BudgetTier _budget = BudgetTier.moderate;
  int _groupSize = 1;
  TimeAvailable _time = TimeAvailable.halfDay;
  bool _haveCar = false;

  bool _loading = false;
  List<Map<String, dynamic>> _results = const [];
  String? _error;

  Future<void> _showTravelAgentHelpDialog({
    required String title,
    required String message,
    String? technicalDetails,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.support_agent, color: Color(0xFF00897B)),
              SizedBox(width: 8),
              Expanded(child: Text('Trypr Travel Agent')),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(message),
                if (technicalDetails != null &&
                    technicalDetails.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Details',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      technicalDetails,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (technicalDetails != null && technicalDetails.trim().isNotEmpty)
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: technicalDetails),
                  );
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx).showTryprSnackBar(
                    const SnackBar(content: Text('Copied error details')),
                  );
                },
                child: const Text('Copy details'),
              ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00897B),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                _generate();
              },
              child: const Text('Retry'),
            ),
          ],
        );
      },
    );
  }

  ({String title, String message, String details}) _describeFunctionsError(
    FirebaseFunctionsException e,
  ) {
    final code = e.code;
    final message = (e.message ?? '').trim();

    // What the user should understand
    if (code == 'unauthenticated') {
      return (
        title: 'Sign-in required',
        message: 'Please sign in, then try again.',
        details: 'code=$code\nmessage=$message\ndetails=${e.details}',
      );
    }

    if (code == 'permission-denied' && message.contains('PREMIUM_REQUIRED')) {
      // Should normally be handled as PremiumRequiredException, but keep a fallback.
      return (
        title: 'Premium required',
        message: 'AI Suggestions require Trypr Premium for now.',
        details: 'code=$code\nmessage=$message\ndetails=${e.details}',
      );
    }

    if (code == 'failed-precondition') {
      // Common root causes: missing dates, missing coords, Vertex not configured.
      return (
        title: 'Missing configuration or required trip info',
        message:
            message.isNotEmpty
                ? message
                : 'The AI service can’t run yet because required information or backend configuration is missing.',
        details: 'code=$code\nmessage=$message\ndetails=${e.details}',
      );
    }

    if (code == 'internal') {
      return (
        title: 'AI service error',
        message:
            'The AI service returned an error. This is usually a backend configuration issue (Vertex project/permissions) or the provider temporarily failing.',
        details: 'code=$code\nmessage=$message\ndetails=${e.details}',
      );
    }

    return (
      title: 'Couldn’t reach the AI service',
      message: message.isNotEmpty ? message : 'Please try again in a moment.',
      details: 'code=$code\nmessage=$message\ndetails=${e.details}',
    );
  }

  List<ActivityType> get _allowedTypes {
    return const [
      ActivityType.adventure,
      ActivityType.foodDrink,
      ActivityType.cultureMuseum,
      ActivityType.relaxation,
      ActivityType.sightseeing,
      ActivityType.nightlife,
      ActivityType.attractions,
    ];
  }

  @override
  void initState() {
    super.initState();
    if (!_allowedTypes.contains(_type)) {
      _type = _allowedTypes.first;
    }
    if (widget.mode == ActivityFinderMode.routeStop) {
      _routeStayType = _defaultRouteStayTypeForMode(widget.routeMode);
      _budget = _defaultBudgetForRouteMode(widget.routeMode);
      _haveCar = _normalizeRouteMode(widget.routeMode) == 'car';
    }
  }

  Future<void> _generate() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _results = const [];
    });

    try {
      final svc = AiSuggestionsService();
      final preferences = _buildPreferences(
        mode: widget.mode,
        type: _type,
        budget: _budget,
        groupSize: _groupSize,
        timeAvailable: _time,
        haveCar: _haveCar,
        routeStayType: _routeStayType,
        routeFromName: widget.routeFromName,
        routeToName: widget.routeToName,
        routeMode: widget.routeMode,
      );

      // Strict input: no free-text. Only structured preferences.
      final res =
          widget.mode == ActivityFinderMode.routeStop
              ? await svc.suggestAccommodations(
                destinationName: widget.destinationName,
                lat: widget.lat,
                lon: widget.lon,
                startDate: widget.startDate,
                endDate: widget.endDate,
                preferences: preferences,
              )
              : await svc.suggestItinerary(
                destinationName: widget.destinationName,
                lat: widget.lat,
                lon: widget.lon,
                startDate: widget.startDate,
                endDate: widget.endDate,
                preferences: preferences,
              );

      if (!mounted) return;
      setState(() {
        _results = res;
      });
    } on PremiumRequiredException {
      if (!mounted) return;
      Navigator.of(context).pop();
      await showPremiumUpsellDialog(context);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      final desc = _describeFunctionsError(e);
      setState(() {
        _error = '${desc.title}: ${desc.message}';
      });
      await _showTravelAgentHelpDialog(
        title: desc.title,
        message: desc.message,
        technicalDetails: desc.details,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
      await _showTravelAgentHelpDialog(
        title: 'Unexpected error',
        message: 'Something went wrong while generating suggestions.',
        technicalDetails: e.toString(),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<int?> _pickDay() async {
    if (widget.dayCount <= 0) return null;

    var selected = 0;
    return showDialog<int>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Add to which day?'),
          content: StatefulBuilder(
            builder: (ctx2, setState2) {
              return DropdownButton<int>(
                isExpanded: true,
                value: selected,
                items: List.generate(
                  widget.dayCount,
                  (i) =>
                      DropdownMenuItem(value: i, child: Text('Day ${i + 1}')),
                ),
                onChanged: (v) {
                  if (v == null) return;
                  setState2(() => selected = v);
                },
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00897B),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(selected),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final maxH = h * 0.9;

    final content = ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        child: Material(
          color: Colors.white,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),

                  Expanded(
                    child: ListView(
                      children: [
                        GlassCard(
                          borderRadius: 14,
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _sectionTitle(
                                widget.mode == ActivityFinderMode.routeStop
                                    ? 'Stay Type'
                                    : 'Activity Type',
                              ),
                              SizedBox(
                                height: 46,
                                child:
                                    widget.mode == ActivityFinderMode.routeStop
                                        ? ListView(
                                          scrollDirection: Axis.horizontal,
                                          children:
                                              RouteStayType.values.map((type) {
                                                final selected =
                                                    type == _routeStayType;
                                                return Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        right: 10,
                                                      ),
                                                  child: ChoiceChip(
                                                    selectedColor: const Color(
                                                      0xFF00897B,
                                                    ).withValues(alpha: 0.12),
                                                    label: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          _iconForRouteStayType(
                                                            type,
                                                          ),
                                                          size: 18,
                                                          color:
                                                              selected
                                                                  ? const Color(
                                                                    0xFF00897B,
                                                                  )
                                                                  : Colors
                                                                      .black54,
                                                        ),
                                                        const SizedBox(
                                                          width: 6,
                                                        ),
                                                        Text(
                                                          _labelForRouteStayType(
                                                            type,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    selected: selected,
                                                    onSelected:
                                                        (_) => setState(
                                                          () =>
                                                              _routeStayType =
                                                                  type,
                                                        ),
                                                  ),
                                                );
                                              }).toList(),
                                        )
                                        : ListView(
                                          scrollDirection: Axis.horizontal,
                                          children:
                                              _allowedTypes.map((t) {
                                                final selected = t == _type;
                                                return Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        right: 10,
                                                      ),
                                                  child: ChoiceChip(
                                                    selectedColor: const Color(
                                                      0xFF00897B,
                                                    ).withValues(alpha: 0.12),
                                                    label: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          _iconForType(t),
                                                          size: 18,
                                                          color:
                                                              selected
                                                                  ? const Color(
                                                                    0xFF00897B,
                                                                  )
                                                                  : Colors
                                                                      .black54,
                                                        ),
                                                        const SizedBox(
                                                          width: 6,
                                                        ),
                                                        Text(_labelForType(t)),
                                                      ],
                                                    ),
                                                    selected: selected,
                                                    onSelected:
                                                        (_) => setState(
                                                          () => _type = t,
                                                        ),
                                                  ),
                                                );
                                              }).toList(),
                                        ),
                              ),
                              if (widget.mode == ActivityFinderMode.routeStop)
                                Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Text(
                                    _routeModeRecommendation(widget.routeMode),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.black54,
                                    ),
                                  ),
                                ),

                              _sectionTitle('Budget'),
                              ToggleButtons(
                                isSelected: [
                                  _budget == BudgetTier.budget,
                                  _budget == BudgetTier.moderate,
                                  _budget == BudgetTier.luxury,
                                ],
                                onPressed: (idx) {
                                  setState(() {
                                    _budget = BudgetTier.values[idx];
                                  });
                                },
                                borderRadius: BorderRadius.circular(12),
                                constraints: const BoxConstraints(
                                  minHeight: 40,
                                  minWidth: 96,
                                ),
                                children: const [
                                  Text(r'$'),
                                  Text(r'$$'),
                                  Text(r'$$$'),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _labelForBudget(_budget),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.black54,
                                ),
                              ),

                              _sectionTitle('Group Size'),
                              Row(
                                children: [
                                  IconButton(
                                    onPressed: () {
                                      setState(() {
                                        _groupSize = (_groupSize - 1).clamp(
                                          1,
                                          12,
                                        );
                                      });
                                    },
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                    ),
                                  ),
                                  Text(
                                    '$_groupSize',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () {
                                      setState(() {
                                        _groupSize = (_groupSize + 1).clamp(
                                          1,
                                          12,
                                        );
                                      });
                                    },
                                    icon: const Icon(Icons.add_circle_outline),
                                  ),
                                ],
                              ),

                              if (widget.mode !=
                                  ActivityFinderMode.routeStop) ...[
                                _sectionTitle('Time Available'),
                                DropdownButtonFormField<TimeAvailable>(
                                  initialValue: _time,
                                  items:
                                      TimeAvailable.values
                                          .map(
                                            (t) => DropdownMenuItem(
                                              value: t,
                                              child: Text(_labelForTime(t)),
                                            ),
                                          )
                                          .toList(),
                                  onChanged: (v) {
                                    if (v == null) return;
                                    setState(() => _time = v);
                                  },
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ],

                              _sectionTitle('Have a Car?'),
                              Row(
                                children: [
                                  Expanded(
                                    child: ToggleButtons(
                                      isSelected: [
                                        _haveCar == false,
                                        _haveCar == true,
                                      ],
                                      onPressed: (idx) {
                                        setState(() => _haveCar = idx == 1);
                                      },
                                      borderRadius: BorderRadius.circular(12),
                                      constraints: const BoxConstraints(
                                        minHeight: 40,
                                        minWidth: 90,
                                      ),
                                      children: const [Text('No'), Text('Yes')],
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00897B),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onPressed: _loading ? null : _generate,
                                  icon:
                                      _loading
                                          ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                          : const Icon(Icons.auto_awesome),
                                  label: Text(
                                    _loading ? 'Generating...' : 'Generate',
                                  ),
                                ),
                              ),
                              if (_error != null) ...[
                                const SizedBox(height: 10),
                                Text(
                                  _error!,
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                        if (_results.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text(
                            'Suggestions',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          ..._results.take(12).map((s) {
                            final name = (s['name'] ?? '').toString();
                            final address = (s['address'] ?? '').toString();
                            final rating =
                                (s['rating'] as num?)?.toDouble() ?? 0;
                            final category = (s['category'] ?? '').toString();
                            final stayTypeRaw =
                                (s['stayType'] ?? '').toString();
                            final stayType =
                                stayTypeRaw.trim().isNotEmpty
                                    ? stayTypeRaw
                                    : _labelForRouteStayType(_routeStayType);
                            final price =
                                (s['estimatedPrice'] as num?)?.toDouble() ??
                                (s['price'] as num?)?.toDouble() ??
                                0;

                            final actionLabel =
                                widget.mode == ActivityFinderMode.routeStop
                                    ? 'Add Stop to Trip'
                                    : 'Add to Itinerary';

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: GlassCard(
                                borderRadius: 14,
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name.isEmpty ? 'Suggestion' : name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      address,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.black54,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        if (widget.mode ==
                                            ActivityFinderMode.routeStop)
                                          Chip(
                                            visualDensity:
                                                VisualDensity.compact,
                                            label: Text(stayType),
                                          )
                                        else if (category.trim().isNotEmpty)
                                          Chip(
                                            visualDensity:
                                                VisualDensity.compact,
                                            label: Text(category),
                                          ),
                                        Chip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            rating > 0
                                                ? 'Rating: ${rating.toStringAsFixed(1)}'
                                                : 'Rating: —',
                                          ),
                                        ),
                                        Chip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            price > 0
                                                ? 'Est: ${price.toStringAsFixed(0)}'
                                                : 'Est: —',
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton.icon(
                                        style: TextButton.styleFrom(
                                          foregroundColor: const Color(
                                            0xFF00897B,
                                          ),
                                        ),
                                        onPressed: () async {
                                          if (widget.mode ==
                                              ActivityFinderMode.routeStop) {
                                            await widget.onAddStop?.call(s);
                                            return;
                                          }

                                          final day = await _pickDay();
                                          if (day == null) return;
                                          await widget.onAddToItinerary(day, s);
                                        },
                                        icon: const Icon(Icons.add),
                                        label: Text(actionLabel),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ],

                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return content;
  }
}
