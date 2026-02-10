import 'package:flutter/material.dart';
import 'package:trypr/widgets/map_embed.dart';

/// A travel blog-style detail view for verified trips
class VerifiedTripDetailScreen extends StatefulWidget {
  final String tripId;
  final Map<String, dynamic> tripData;

  const VerifiedTripDetailScreen({
    super.key,
    required this.tripId,
    required this.tripData,
  });

  static Route<void> route({
    required String tripId,
    required Map<String, dynamic> tripData,
  }) {
    return MaterialPageRoute<void>(
      builder:
          (_) => VerifiedTripDetailScreen(tripId: tripId, tripData: tripData),
    );
  }

  @override
  State<VerifiedTripDetailScreen> createState() =>
      _VerifiedTripDetailScreenState();
}

class _VerifiedTripDetailScreenState extends State<VerifiedTripDetailScreen> {
  final ScrollController _scrollController = ScrollController();
  double _scrollOffset = 0;

  // Travel-themed categories with colors for activities
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
    'Driving': Colors.blueAccent,
  };

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    setState(() {
      _scrollOffset = _scrollController.offset;
    });
  }

  String get _title => (widget.tripData['title'] ?? 'Verified Trip').toString();
  String get _subtitle => (widget.tripData['subtitle'] ?? '').toString();
  String get _description => (widget.tripData['description'] ?? '').toString();
  String get _coverImage => (widget.tripData['coverImage'] ?? '').toString();
  int get _recommendedDays =>
      widget.tripData['recommendedDays'] ?? widget.tripData['days'] ?? 0;
  int get _totalStops => widget.tripData['totalStops'] ?? 0;
  double get _totalKm => (widget.tripData['totalKm'] ?? 0).toDouble();

  List<Map<String, dynamic>> get _waypoints {
    final wps = widget.tripData['waypoints'];
    if (wps is! List) return [];
    return wps
        .map(
          (w) => w is Map ? Map<String, dynamic>.from(w) : <String, dynamic>{},
        )
        .toList();
  }

  List<String> get _photos {
    final photos = widget.tripData['photos'];
    if (photos is! List) return [];
    return photos.map((p) => p.toString()).where((p) => p.isNotEmpty).toList();
  }

  List<Map<String, dynamic>> get _itinerary {
    final it = widget.tripData['itinerary'];
    if (it is! List) return [];
    return it
        .map(
          (d) => d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{},
        )
        .toList();
  }

  List<Map<String, dynamic>> get _mapPoints {
    return _waypoints
        .map(
          (w) => {
            'lat': (w['lat'] ?? w['latitude'] ?? 0.0),
            'lon': (w['lon'] ?? w['longitude'] ?? w['lng'] ?? 0.0),
            'name': w['name'] ?? '',
          },
        )
        .toList();
  }

  List<Map<String, dynamic>> get _activityMarkers {
    return _itinerary.asMap().entries.expand((dayEntry) {
      final dayIndex = dayEntry.key;
      final day = dayEntry.value;
      final acts = (day['activities'] as List<dynamic>?) ?? [];
      return acts
          .asMap()
          .entries
          .where(
            (a) =>
                (a.value as Map)['locationLat'] != null &&
                (a.value as Map)['locationLon'] != null,
          )
          .map(
            (a) => {
              'lat': (a.value as Map)['locationLat'],
              'lon': (a.value as Map)['locationLon'],
              'kind': 'activity',
              'category': (a.value as Map)['category'] ?? 'Sightseeing',
              'dayIndex': dayIndex,
              'activityIndex': a.key,
            },
          );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide = screenWidth >= 900;
    final heroHeight = isWide ? 500.0 : 350.0;

    // Calculate app bar opacity based on scroll
    final appBarOpacity = (_scrollOffset / (heroHeight - 100)).clamp(0.0, 1.0);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Theme.of(
          context,
        ).scaffoldBackgroundColor.withOpacity(appBarOpacity),
        elevation: appBarOpacity > 0.5 ? 2 : 0,
        leading: IconButton(
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color:
                  appBarOpacity < 0.5
                      ? Colors.black.withOpacity(0.3)
                      : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.arrow_back,
              color: appBarOpacity < 0.5 ? Colors.white : null,
            ),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: AnimatedOpacity(
          opacity: appBarOpacity,
          duration: const Duration(milliseconds: 150),
          child: Text(_title),
        ),
      ),
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // Hero Cover Image
          SliverToBoxAdapter(child: _buildHeroSection(heroHeight)),

          // Content
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 32),

                      // Title & Stats Section
                      _buildTitleSection(),

                      const SizedBox(height: 24),

                      // Description / Intro
                      if (_description.isNotEmpty) ...[
                        _buildDescriptionSection(),
                        const SizedBox(height: 32),
                      ],

                      // Quick Stats Cards
                      _buildStatsCards(),

                      const SizedBox(height: 40),

                      // Route Map
                      _buildMapSection(),

                      const SizedBox(height: 40),

                      // Destinations/Stops
                      if (_waypoints.isNotEmpty) ...[
                        _buildDestinationsSection(),
                        const SizedBox(height: 40),
                      ],

                      // Photo Gallery
                      if (_photos.isNotEmpty) ...[
                        _buildPhotoGallery(),
                        const SizedBox(height: 40),
                      ],

                      // Day-by-Day Itinerary
                      if (_itinerary.isNotEmpty) ...[
                        _buildItinerarySection(),
                        const SizedBox(height: 40),
                      ],

                      const SizedBox(height: 60),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroSection(double height) {
    return Stack(
      children: [
        // Cover Image
        SizedBox(
          height: height,
          width: double.infinity,
          child:
              _coverImage.isNotEmpty
                  ? Image.network(
                    _coverImage,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Container(
                        color: Colors.grey[300],
                        child: const Center(child: CircularProgressIndicator()),
                      );
                    },
                    errorBuilder: (_, error, ___) {
                      debugPrint('Cover image error: $error');
                      return Container(
                        color: Colors.grey[300],
                        child: const Icon(
                          Icons.image,
                          size: 80,
                          color: Colors.grey,
                        ),
                      );
                    },
                  )
                  : Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Colors.teal.shade400, Colors.blue.shade600],
                      ),
                    ),
                    child: const Icon(
                      Icons.travel_explore,
                      size: 100,
                      color: Colors.white54,
                    ),
                  ),
        ),

        // Gradient overlay
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withOpacity(0.1),
                  Colors.black.withOpacity(0.6),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
        ),

        // Title on image
        Positioned(
          left: 24,
          right: 24,
          bottom: 32,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_subtitle.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00B894),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _subtitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                _title,
                style: const TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  shadows: [Shadow(blurRadius: 10, color: Colors.black54)],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTitleSection() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF00B894).withOpacity(0.15),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.verified, color: Color(0xFF00B894), size: 32),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Verified Adventure',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF00B894),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'A curated ${_recommendedDays}-day journey through ${_totalStops} amazing destinations',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDescriptionSection() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_stories, color: Colors.grey[700], size: 22),
              const SizedBox(width: 10),
              Text(
                'About This Trip',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey[800],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _description,
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[700],
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsCards() {
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        _StatCard(
          icon: Icons.calendar_today,
          value: '$_recommendedDays',
          label: 'Days',
          color: Colors.blue,
        ),
        _StatCard(
          icon: Icons.place,
          value: '$_totalStops',
          label: 'Stops',
          color: Colors.orange,
        ),
        _StatCard(
          icon: Icons.straighten,
          value: '${_totalKm.toStringAsFixed(0)} km',
          label: 'Distance',
          color: Colors.teal,
        ),
        _StatCard(
          icon: Icons.photo_library,
          value: '${_photos.length}',
          label: 'Photos',
          color: Colors.purple,
        ),
      ],
    );
  }

  Widget _buildMapSection() {
    if (_mapPoints.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.map, color: Colors.grey[700], size: 24),
            const SizedBox(width: 10),
            Text(
              'Route Overview',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.grey[800],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 350,
            child: MapEmbed(
              points: _mapPoints,
              secondaryPoints: _activityMarkers,
              disableDefaultUi: false,
              zoomControlsEnabled: true,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDestinationsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.flag, color: Colors.grey[700], size: 24),
            const SizedBox(width: 10),
            Text(
              'Destinations',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.grey[800],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...List.generate(_waypoints.length, (index) {
          final wp = _waypoints[index];
          final name = wp['name']?.toString() ?? 'Stop ${index + 1}';
          final days = wp['days'] ?? 1;
          final isLast = index == _waypoints.length - 1;

          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Timeline
                SizedBox(
                  width: 40,
                  child: Column(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: const Color(0xFF00B894),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF00B894).withOpacity(0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                      if (!isLast)
                        Expanded(
                          child: Container(
                            width: 2,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            color: Colors.grey[300],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Content
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade200),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$days ${days == 1 ? 'day' : 'days'}',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right, color: Colors.grey[400]),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildPhotoGallery() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.photo_library, color: Colors.grey[700], size: 24),
            const SizedBox(width: 10),
            Text(
              'Photo Gallery',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.grey[800],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 200,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _photos.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              return GestureDetector(
                onTap: () => _showPhotoViewer(index),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: Image.network(
                      _photos[index],
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Container(
                          color: Colors.grey[200],
                          child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      },
                      errorBuilder: (_, error, ___) {
                        debugPrint('Photo gallery error: $error');
                        return Container(
                          color: Colors.grey[200],
                          child: const Icon(Icons.broken_image),
                        );
                      },
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

  void _showPhotoViewer(int initialIndex) {
    showDialog(
      context: context,
      builder:
          (ctx) => Dialog(
            backgroundColor: Colors.black,
            insetPadding: const EdgeInsets.all(16),
            child: Stack(
              children: [
                PageView.builder(
                  controller: PageController(initialPage: initialIndex),
                  itemCount: _photos.length,
                  itemBuilder:
                      (_, i) => InteractiveViewer(
                        child: Center(
                          child: Image.network(_photos[i], fit: BoxFit.contain),
                        ),
                      ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  Widget _buildItinerarySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.schedule, color: Colors.grey[700], size: 24),
            const SizedBox(width: 10),
            Text(
              'Day-by-Day Itinerary',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.grey[800],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        ...List.generate(_itinerary.length, (dayIndex) {
          final day = _itinerary[dayIndex];
          final title = day['title']?.toString() ?? 'Day ${dayIndex + 1}';
          final notes = day['notes']?.toString() ?? '';
          final activities = (day['activities'] as List<dynamic>?) ?? [];

          return Container(
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.shade200),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Day Header
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00B894).withOpacity(0.1),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00B894),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Day ${dayIndex + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title != 'Day ${dayIndex + 1}' ? title : '',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        '${activities.length} ${activities.length == 1 ? 'activity' : 'activities'}',
                        style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),

                // Notes
                if (notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text(
                      notes,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),

                // Activities
                if (activities.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: List.generate(activities.length, (actIndex) {
                        final act = activities[actIndex];
                        final time = act['time']?.toString() ?? '';
                        final actTitle = act['title']?.toString() ?? '';
                        final actDesc = act['description']?.toString() ?? '';
                        final actLocation = act['location']?.toString() ?? '';
                        final actCategory = act['category']?.toString() ?? '';

                        return Padding(
                          padding: EdgeInsets.only(
                            bottom: actIndex < activities.length - 1 ? 12 : 0,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Time
                              SizedBox(
                                width: 70,
                                child: Text(
                                  time.isNotEmpty ? time : '•',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey[500],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              // Activity details
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        if (actLocation.trim().isNotEmpty &&
                                            actCategory.isNotEmpty &&
                                            travelCategories.containsKey(
                                              actCategory,
                                            ))
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 4,
                                            ),
                                            child: Container(
                                              width: 10,
                                              height: 10,
                                              decoration: BoxDecoration(
                                                color:
                                                    travelCategories[actCategory],
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                          ),
                                        if (actLocation.trim().isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 6,
                                            ),
                                            child: Icon(
                                              Icons.place,
                                              size: 16,
                                              color: Colors.blue[700],
                                            ),
                                          ),
                                        Expanded(
                                          child: Text(
                                            actTitle,
                                            style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (actLocation.trim().isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        '📍 ${actLocation.trim()}',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Colors.blue[600],
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                    if (actDesc.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        actDesc,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ),
                  ),

                if (activities.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No activities planned yet',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[400],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
