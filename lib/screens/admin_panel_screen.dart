import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:flutter/services.dart';
import 'package:trypr/screens/trip_detail_screen.dart';
import 'package:trypr/screens/unlisted_page_builder_screen.dart';
import 'package:trypr/screens/unlisted_page_responses_screen.dart';
import 'package:trypr/screens/verified_trip_builder_screen.dart';
import 'package:intl/intl.dart';

/// POWER ADMIN PANEL - Complete platform control center
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  static Route<void> route() {
    return MaterialPageRoute<void>(builder: (_) => const AdminPanelScreen());
  }

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 8, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.admin_panel_settings, color: Color(0xFFFFD700)),
            SizedBox(width: 12),
            Text('Admin Control Center'),
          ],
        ),
        backgroundColor: const Color(0xFF1a1a2e),
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: const Color(0xFF00B894),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(icon: Icon(Icons.dashboard), text: 'Dashboard'),
            Tab(icon: Icon(Icons.people), text: 'Users'),
            Tab(icon: Icon(Icons.map), text: 'Trips'),
            Tab(icon: Icon(Icons.verified), text: 'Verified'),
            Tab(icon: Icon(Icons.link), text: 'Pages'),
            Tab(icon: Icon(Icons.analytics), text: 'Analytics'),
            Tab(icon: Icon(Icons.note_add), text: 'My Notes'),
            Tab(icon: Icon(Icons.settings), text: 'Settings'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _DashboardTab(tabController: _tabController),
          _UsersManagementTab(),
          _TripsManagementTab(),
          _VerifiedTripsManagementTab(),
          _UnlistedPagesTab(),
          _AnalyticsTab(),
          _PersonalNotesTab(),
          _SettingsTab(),
        ],
      ),
    );
  }
}

// ============================================================================
// DASHBOARD TAB - Quick overview and stats
// ============================================================================
class _DashboardTab extends StatelessWidget {
  final TabController tabController;

  const _DashboardTab({required this.tabController});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildWelcomeCard(context),
          const SizedBox(height: 24),
          _buildQuickStats(),
          const SizedBox(height: 24),
          _buildRecentActivity(),
          const SizedBox(height: 24),
          _buildQuickActions(context),
        ],
      ),
    );
  }

  Widget _buildWelcomeCard(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final hour = DateTime.now().hour;
    String greeting =
        hour < 12
            ? 'Good morning'
            : hour < 18
            ? 'Good afternoon'
            : 'Good evening';

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF667eea), Color(0xFF764ba2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$greeting, ${user?.displayName ?? 'Admin'}! 👋',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Welcome to your command center',
            style: TextStyle(fontSize: 16, color: Colors.white70),
          ),
          const SizedBox(height: 16),
          Text(
            DateFormat('EEEE, MMMM d, y').format(DateTime.now()),
            style: const TextStyle(color: Colors.white60),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickStats() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Platform Overview',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        FutureBuilder<List<int>>(
          future: _getQuickStats(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final stats = snapshot.data!;
            final usersCount = stats[0];
            final verifiedTripsCount = stats[1];
            final pagesCount = stats[2];

            return LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 800;
                return Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _StatCard(
                      title: 'Total Users',
                      value: usersCount.toString(),
                      icon: Icons.people,
                      color: const Color(0xFF6c5ce7),
                      width: isWide ? (constraints.maxWidth - 48) / 4 : null,
                    ),
                    _StatCard(
                      title: 'Verified Trips',
                      value: verifiedTripsCount.toString(),
                      icon: Icons.verified,
                      color: const Color(0xFF00B894),
                      width: isWide ? (constraints.maxWidth - 48) / 4 : null,
                    ),
                    _StatCard(
                      title: 'Unlisted Pages',
                      value: pagesCount.toString(),
                      icon: Icons.link,
                      color: const Color(0xFFe17055),
                      width: isWide ? (constraints.maxWidth - 48) / 4 : null,
                    ),
                    _StatCard(
                      title: 'Active Today',
                      value: '0', // Implement with analytics
                      icon: Icons.trending_up,
                      color: const Color(0xFFfdcb6e),
                      width: isWide ? (constraints.maxWidth - 48) / 4 : null,
                    ),
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  Future<List<int>> _getQuickStats() async {
    final users = await FirebaseFirestore.instance.collection('users').get();
    final verifiedTrips =
        await FirebaseFirestore.instance.collection('verifiedTrips').get();
    final pages =
        await FirebaseFirestore.instance.collection('unlistedPages').get();
    return [users.docs.length, verifiedTrips.docs.length, pages.docs.length];
  }

  Widget _buildRecentActivity() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recent Activity',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        StreamBuilder<QuerySnapshot>(
          stream:
              FirebaseFirestore.instance
                  .collection('users')
                  .orderBy('createdAt', descending: true)
                  .limit(5)
                  .snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const CircularProgressIndicator();
            }

            final users = snapshot.data!.docs;
            if (users.isEmpty) {
              return const Text('No recent activity');
            }

            return Card(
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: users.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final data = users[index].data() as Map<String, dynamic>;
                  final name = data['displayName'] ?? 'Unknown User';
                  final createdAt = data['createdAt'] as Timestamp?;
                  final timeAgo =
                      createdAt != null
                          ? _timeAgo(createdAt.toDate())
                          : 'Recently';

                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFF00B894),
                      child: Text(
                        name[0].toUpperCase(),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    title: Text(name),
                    subtitle: Text('Joined $timeAgo'),
                    trailing: const Icon(Icons.person_add, size: 20),
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quick Actions',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _ActionButton(
              label: 'Create Verified Trip',
              icon: Icons.add_location,
              color: const Color(0xFF00B894),
              onTap: () {
                Navigator.of(context).push(VerifiedTripBuilderScreen.route());
              },
            ),
            _ActionButton(
              label: 'New Unlisted Page',
              icon: Icons.note_add,
              color: const Color(0xFF6c5ce7),
              onTap: () {
                Navigator.of(context).push(UnlistedPageBuilderScreen.route());
              },
            ),
            _ActionButton(
              label: 'View Analytics',
              icon: Icons.analytics,
              color: const Color(0xFFe17055),
              onTap: () {
                tabController.animateTo(5);
              },
            ),
            _ActionButton(
              label: 'Manage Users',
              icon: Icons.people_alt,
              color: const Color(0xFFfdcb6e),
              onTap: () {
                tabController.animateTo(1);
              },
            ),
          ],
        ),
      ],
    );
  }

  String _timeAgo(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inDays > 365) return '${diff.inDays ~/ 365}y ago';
    if (diff.inDays > 30) return '${diff.inDays ~/ 30}mo ago';
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'Just now';
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final double? width;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width ?? 160,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(title, style: TextStyle(fontSize: 14, color: Colors.grey[600])),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// USERS MANAGEMENT TAB
// ============================================================================
class _UsersManagementTab extends StatefulWidget {
  @override
  State<_UsersManagementTab> createState() => _UsersManagementTabState();
}

class _UsersManagementTabState extends State<_UsersManagementTab> {
  String _searchQuery = '';
  String _sortBy = 'createdAt';
  bool _ascending = false;

  String _tripDateLabel(dynamic raw) {
    if (raw == null) return '';
    if (raw is Timestamp) {
      return DateFormat('MMM d, y').format(raw.toDate());
    }
    final text = raw.toString().trim();
    if (text.isEmpty) return '';
    final parsed = DateTime.tryParse(text);
    if (parsed != null) return DateFormat('MMM d, y').format(parsed);
    return text;
  }

  String _tripDateRangeSubtitle(Map<String, dynamic> data) {
    final start = _tripDateLabel(data['startDate']);
    final end = _tripDateLabel(data['endDate']);
    if (start.isNotEmpty && end.isNotEmpty) return '$start - $end';
    if (start.isNotEmpty) return start;
    if (end.isNotEmpty) return end;
    return 'No dates set';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.grey[100],
          child: Column(
            children: [
              TextField(
                decoration: InputDecoration(
                  hintText: 'Search users by name or email...',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (value) {
                  setState(() => _searchQuery = value.toLowerCase());
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Sort by: '),
                  DropdownButton<String>(
                    value: _sortBy,
                    items: const [
                      DropdownMenuItem(
                        value: 'createdAt',
                        child: Text('Join Date'),
                      ),
                      DropdownMenuItem(
                        value: 'displayName',
                        child: Text('Name'),
                      ),
                      DropdownMenuItem(value: 'email', child: Text('Email')),
                    ],
                    onChanged: (value) {
                      setState(() => _sortBy = value!);
                    },
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: Icon(
                      _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    ),
                    onPressed: () {
                      setState(() => _ascending = !_ascending);
                    },
                    tooltip: _ascending ? 'Ascending' : 'Descending',
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream:
                FirebaseFirestore.instance
                    .collection('users')
                    .orderBy(_sortBy, descending: !_ascending)
                    .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}'));
              }

              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              var docs = snapshot.data!.docs;

              // Filter by search query
              if (_searchQuery.isNotEmpty) {
                docs =
                    docs.where((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      final name =
                          (data['displayName'] ?? '').toString().toLowerCase();
                      final email =
                          (data['email'] ?? '').toString().toLowerCase();
                      return name.contains(_searchQuery) ||
                          email.contains(_searchQuery);
                    }).toList();
              }

              if (docs.isEmpty) {
                return const Center(child: Text('No users found'));
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  final data = doc.data() as Map<String, dynamic>;
                  final userId = doc.id;
                  final name = data['displayName'] ?? 'Unknown';
                  final email = data['email'] ?? '';
                  final city = data['city'] ?? '';
                  final createdAt = data['createdAt'] as Timestamp?;
                  final visited =
                      (data['visitedCountries'] as List<dynamic>?)?.length ?? 0;

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ExpansionTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFF00B894),
                        child: Text(
                          name[0].toUpperCase(),
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      title: Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (email.isNotEmpty) Text(email),
                          if (city.isNotEmpty)
                            Text(
                              '📍 $city',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          Text(
                            'Joined ${createdAt != null ? DateFormat('MMM d, y').format(createdAt.toDate()) : 'recently'}',
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _InfoRow('User ID:', userId),
                              _InfoRow(
                                'Countries Visited:',
                                visited.toString(),
                              ),
                              _InfoRow('Sex:', data['sex'] ?? 'Not specified'),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  ElevatedButton.icon(
                                    onPressed:
                                        () => _viewUserTrips(
                                          context,
                                          userId,
                                          name,
                                        ),
                                    icon: const Icon(Icons.map, size: 16),
                                    label: const Text('View Trips'),
                                  ),
                                  ElevatedButton.icon(
                                    onPressed:
                                        () => _editUser(context, userId, data),
                                    icon: const Icon(Icons.edit, size: 16),
                                    label: const Text('Edit User'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF6c5ce7),
                                    ),
                                  ),
                                  ElevatedButton.icon(
                                    onPressed:
                                        () => _makeAdmin(context, userId, name),
                                    icon: const Icon(
                                      Icons.admin_panel_settings,
                                      size: 16,
                                    ),
                                    label: const Text('Make Admin'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFe17055),
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed:
                                        () =>
                                            _deleteUser(context, userId, name),
                                    icon: const Icon(Icons.delete, size: 16),
                                    label: const Text('Delete'),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _viewUserTrips(
    BuildContext context,
    String userId,
    String userName,
  ) async {
    QuerySnapshot<Map<String, dynamic>> trips;
    try {
      trips =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(userId)
              .collection('trips')
              .get();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(content: Text('Could not load trips: $e')),
        );
      }
      return;
    }

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text('$userName\'s Trips'),
            content: SizedBox(
              width: 400,
              height: 500,
              child:
                  trips.docs.isEmpty
                      ? const Center(child: Text('No trips yet'))
                      : ListView.builder(
                        itemCount: trips.docs.length,
                        itemBuilder: (_, i) {
                          final data = trips.docs[i].data();
                          final tripId = trips.docs[i].id;
                          final title =
                              (data['name'] ??
                                      data['tripName'] ??
                                      'Untitled Trip')
                                  .toString();
                          final subtitle = _tripDateRangeSubtitle(data);

                          return ListTile(
                            leading: const Icon(Icons.map),
                            title: Text(title),
                            subtitle: Text(
                              subtitle,
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () async {
                              Navigator.pop(ctx);
                              final tripPath = 'users/$userId/trips/$tripId';

                              try {
                                final tripDoc =
                                    await FirebaseFirestore.instance
                                        .doc(tripPath)
                                        .get();

                                if (!context.mounted) return;
                                if (!tripDoc.exists) {
                                  ScaffoldMessenger.of(
                                    context,
                                  ).showTryprSnackBar(
                                    const SnackBar(
                                      content: Text('Trip no longer exists'),
                                    ),
                                  );
                                  return;
                                }

                                final tripData = Map<String, dynamic>.from(
                                  tripDoc.data() ?? {},
                                );
                                // Admin views should open against the real trip path.
                                tripData['tripRef'] = tripPath;
                                tripData.remove('sharedFrom');

                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder:
                                        (_) => TripDetailScreen(
                                          docId: tripId,
                                          data: tripData,
                                          readOnly: true,
                                        ),
                                  ),
                                );
                              } catch (e) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showTryprSnackBar(
                                  SnackBar(
                                    content: Text('Could not open trip: $e'),
                                  ),
                                );
                              }
                            },
                          );
                        },
                      ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }

  Future<void> _makeAdmin(
    BuildContext context,
    String userId,
    String userName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Grant Admin Access'),
            content: Text('Make $userName an admin?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFe17055),
                ),
                child: const Text('Confirm'),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      try {
        await FirebaseFirestore.instance.collection('admins').doc(userId).set({
          'createdAt': FieldValue.serverTimestamp(),
        });
        if (context.mounted) {
          ScaffoldMessenger.of(context).showTryprSnackBar(
            SnackBar(content: Text('$userName is now an admin')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showTryprSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }

  Future<void> _editUser(
    BuildContext context,
    String userId,
    Map<String, dynamic> currentData,
  ) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _EditUserDialog(currentData: currentData),
    );

    if (result != null && context.mounted) {
      try {
        final updates = <String, dynamic>{};

        if (result['name'] != currentData['name']) {
          updates['name'] = result['name'];
        }
        if (result['bio'] != currentData['bio']) {
          updates['bio'] = result['bio'];
        }
        if (result['sex'] != currentData['sex']) {
          updates['sex'] = result['sex'];
        }

        if (updates.isNotEmpty) {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(userId)
              .update(updates);

          if (context.mounted) {
            ScaffoldMessenger.of(context).showTryprSnackBar(
              const SnackBar(content: Text('User details updated')),
            );
          }
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showTryprSnackBar(
            SnackBar(content: Text('Error updating user: $e')),
          );
        }
      }
    }
  }

  Future<void> _deleteUser(
    BuildContext context,
    String userId,
    String userName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete User'),
            content: Text(
              'Are you sure you want to delete $userName? This will delete all their trips and data. This action cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      try {
        // Note: In production, you'd want to use a Cloud Function to properly
        // delete all user data, including Auth user and subcollections
        await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .delete();
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showTryprSnackBar(SnackBar(content: Text('Deleted $userName')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showTryprSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

// ============================================================================
// TRIPS MANAGEMENT TAB (All user trips)
// ============================================================================
class _TripsManagementTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collectionGroup('trips').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final trips = snapshot.data!.docs;

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: trips.length,
          itemBuilder: (context, index) {
            final doc = trips[index];
            final data = doc.data() as Map<String, dynamic>;
            final tripName = data['name'] ?? 'Untitled Trip';
            final startDate = data['startDate'] ?? '';
            final waypoints =
                (data['waypoints'] as List<dynamic>?)?.length ?? 0;

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFF00B894),
                  child: Icon(Icons.map, color: Colors.white),
                ),
                title: Text(tripName),
                subtitle: Text('$waypoints destinations • Starts: $startDate'),
                trailing: PopupMenuButton(
                  itemBuilder:
                      (context) => [
                        const PopupMenuItem(
                          value: 'view',
                          child: Text('View Details'),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      ],
                  onSelected: (value) {
                    if (value == 'delete') {
                      _deleteTrip(context, doc.reference, tripName);
                    }
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _deleteTrip(
    BuildContext context,
    DocumentReference ref,
    String tripName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete Trip'),
            content: Text('Delete "$tripName"?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      try {
        await ref.delete();
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showTryprSnackBar(const SnackBar(content: Text('Trip deleted')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showTryprSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }
}

// ============================================================================
// VERIFIED TRIPS MANAGEMENT TAB
// ============================================================================
class _VerifiedTripsManagementTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.green[50],
          child: Row(
            children: [
              const Icon(Icons.verified, color: Color(0xFF00B894)),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Manage curated trips shown to all users',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(VerifiedTripBuilderScreen.route());
                },
                icon: const Icon(Icons.add),
                label: const Text('New Trip'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00B894),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream:
                FirebaseFirestore.instance
                    .collection('verifiedTrips')
                    .orderBy('createdAt', descending: true)
                    .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final trips = snapshot.data!.docs;

              if (trips.isEmpty) {
                return const Center(child: Text('No verified trips yet'));
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: trips.length,
                itemBuilder: (context, index) {
                  final doc = trips[index];
                  final data = doc.data() as Map<String, dynamic>;
                  final title = data['title'] ?? 'Untitled';
                  final subtitle = data['subtitle'] ?? '';
                  final waypoints =
                      (data['waypoints'] as List<dynamic>?)?.length ?? 0;
                  final emoji = data['emoji'] ?? '🗺️';

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.green[100],
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 24),
                        ),
                      ),
                      title: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (subtitle.isNotEmpty) Text(subtitle),
                          Text(
                            '$waypoints destinations',
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                      trailing: PopupMenuButton(
                        itemBuilder:
                            (context) => [
                              const PopupMenuItem(
                                value: 'edit',
                                child: Text('Edit'),
                              ),
                              const PopupMenuItem(
                                value: 'duplicate',
                                child: Text('Duplicate'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                        onSelected: (value) {
                          if (value == 'edit') {
                            Navigator.of(context).push(
                              VerifiedTripBuilderScreen.route(
                                existingTripId: doc.id,
                                existingTripData: data,
                              ),
                            );
                          } else if (value == 'delete') {
                            _deleteVerifiedTrip(context, doc.id, title);
                          }
                        },
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _deleteVerifiedTrip(
    BuildContext context,
    String tripId,
    String title,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete Verified Trip'),
            content: Text(
              'Delete "$title"? This will remove it for all users.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      try {
        await FirebaseFirestore.instance
            .collection('verifiedTrips')
            .doc(tripId)
            .delete();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showTryprSnackBar(
            const SnackBar(content: Text('Verified trip deleted')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showTryprSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }
}

class _UnlistedPagesTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream:
          FirebaseFirestore.instance
              .collection('unlistedPages')
              .orderBy('createdAt', descending: true)
              .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data!.docs;

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.link_off, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text(
                  'No unlisted pages yet',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Create your first unlisted page',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc = docs[index];
            final data = doc.data();
            final pageId = doc.id;
            final title = data['title']?.toString() ?? 'Untitled';
            final description = data['description']?.toString() ?? '';
            final formEnabled = data['formEnabled'] == true;
            final createdAt = data['createdAt'] as Timestamp?;

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00B894).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.article_outlined,
                    color: Color(0xFF00B894),
                  ),
                ),
                title: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _StatusChip(
                          label: '/page/$pageId',
                          color: Colors.blue,
                          icon: Icons.link,
                        ),
                        const SizedBox(width: 8),
                        if (formEnabled)
                          _StatusChip(
                            label: 'Form',
                            color: Colors.green,
                            icon: Icons.edit_note,
                          ),
                      ],
                    ),
                  ],
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    switch (value) {
                      case 'edit':
                        Navigator.of(context).push(
                          UnlistedPageBuilderScreen.route(
                            existingPageId: pageId,
                            existingPageData: data,
                          ),
                        );
                        break;
                      case 'copy_link':
                        final url = '${Uri.base.origin}/page/$pageId';
                        Clipboard.setData(ClipboardData(text: url));
                        ScaffoldMessenger.of(context).showTryprSnackBar(
                          const SnackBar(content: Text('Link copied')),
                        );
                        break;
                      case 'view_responses':
                        _showResponses(context, pageId, title);
                        break;
                      case 'delete':
                        _confirmDelete(context, pageId, title);
                        break;
                    }
                  },
                  itemBuilder:
                      (context) => [
                        const PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit, size: 20),
                              SizedBox(width: 12),
                              Text('Edit'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'copy_link',
                          child: Row(
                            children: [
                              Icon(Icons.link, size: 20),
                              SizedBox(width: 12),
                              Text('Copy Link'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'view_responses',
                          child: Row(
                            children: [
                              Icon(Icons.list_alt, size: 20),
                              SizedBox(width: 12),
                              Text('View Responses'),
                            ],
                          ),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete, size: 20, color: Colors.red),
                              SizedBox(width: 12),
                              Text(
                                'Delete',
                                style: TextStyle(color: Colors.red),
                              ),
                            ],
                          ),
                        ),
                      ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showResponses(BuildContext context, String pageId, String pageTitle) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => UnlistedPageResponsesScreen(
              pageSlug: pageId,
              pageTitle: pageTitle,
            ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    String pageId,
    String title,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete Page?'),
            content: Text(
              'Are you sure you want to delete "$title"? This will also delete all responses.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      try {
        await FirebaseFirestore.instance
            .collection('unlistedPages')
            .doc(pageId)
            .delete();
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showTryprSnackBar(const SnackBar(content: Text('Page deleted')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showTryprSnackBar(SnackBar(content: Text('Error deleting: $e')));
        }
      }
    }
  }
}

class _ResponsesTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream:
          FirebaseFirestore.instance.collection('unlistedPages').snapshots(),
      builder: (context, pagesSnapshot) {
        if (!pagesSnapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final pages = pagesSnapshot.data!.docs;
        if (pages.isEmpty) {
          return const Center(child: Text('No pages yet'));
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: pages.length,
          itemBuilder: (context, index) {
            final page = pages[index];
            final pageId = page.id;
            final title = page.data()['title']?.toString() ?? 'Untitled';

            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream:
                  FirebaseFirestore.instance
                      .collection('unlistedPages')
                      .doc(pageId)
                      .collection('responses')
                      .orderBy('submittedAt', descending: true)
                      .snapshots(),
              builder: (context, responsesSnapshot) {
                final responseCount = responsesSnapshot.data?.docs.length ?? 0;

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFF00B894),
                      child: Text(
                        '$responseCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(title),
                    subtitle: Text('$responseCount responses'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        useSafeArea: true,
                        builder:
                            (context) => DraggableScrollableSheet(
                              initialChildSize: 0.9,
                              minChildSize: 0.5,
                              maxChildSize: 0.95,
                              expand: false,
                              builder:
                                  (context, scrollController) =>
                                      _ResponsesSheet(
                                        pageId: pageId,
                                        pageTitle: title,
                                        scrollController: scrollController,
                                      ),
                            ),
                      );
                    },
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _ResponsesSheet extends StatelessWidget {
  final String pageId;
  final String pageTitle;
  final ScrollController scrollController;

  const _ResponsesSheet({
    required this.pageId,
    required this.pageTitle,
    required this.scrollController,
  });

  static const Set<String> _responseMetaKeys = {
    'submittedAt',
    'submittedByUid',
    'submittedByEmail',
    'submittedByName',
    'responses',
    'formattedResponses',
  };

  bool _looksLikeFieldId(String value) {
    final v = value.trim().toLowerCase();
    return v.startsWith('field_') || v.startsWith('fld_');
  }

  int _fieldOrder(String? fieldId, Map<String, Map<String, dynamic>> fieldMap) {
    if (fieldId == null || fieldId.isEmpty) return 1 << 30;
    final order = fieldMap[fieldId]?['order'];
    if (order is int) return order;
    if (order is num) return order.toInt();
    return 1 << 30;
  }

  String _humanizeFieldId(String value) {
    var out = value;
    if (out.startsWith('field_')) out = out.substring('field_'.length);
    out = out.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
    out = out.replaceAll(RegExp(r'\d+$'), '').trim();
    if (out.isEmpty) return '';
    return out
        .split(' ')
        .where((p) => p.isNotEmpty)
        .map((p) => '${p[0].toUpperCase()}${p.substring(1)}')
        .join(' ');
  }

  String _resolveLabel({
    required String? fieldId,
    required String? fallbackLabel,
    required int fallbackIndex,
    required Map<String, Map<String, dynamic>> fieldMap,
  }) {
    if (fieldId != null && fieldId.isNotEmpty) {
      final mapped = fieldMap[fieldId]?['label']?.toString();
      if (mapped != null && mapped.trim().isNotEmpty) return mapped.trim();
    }

    final label = (fallbackLabel ?? '').trim();
    if (label.isNotEmpty) {
      if (fieldMap.containsKey(label)) {
        final mapped = fieldMap[label]?['label']?.toString();
        if (mapped != null && mapped.trim().isNotEmpty) return mapped.trim();
      }
      if (!_looksLikeFieldId(label)) return label;
      final humanized = _humanizeFieldId(label);
      if (humanized.isNotEmpty) return humanized;
    }

    if (fieldId != null && fieldId.isNotEmpty) {
      final humanized = _humanizeFieldId(fieldId);
      if (humanized.isNotEmpty) return humanized;
    }

    return 'Field ${fallbackIndex + 1}';
  }

  String _resolveType({
    required String? fieldId,
    required String? fallbackType,
    required Map<String, Map<String, dynamic>> fieldMap,
  }) {
    if (fieldId != null && fieldId.isNotEmpty) {
      final mapped = fieldMap[fieldId]?['type']?.toString();
      if (mapped != null && mapped.trim().isNotEmpty) return mapped.trim();
    }
    final t = (fallbackType ?? '').trim();
    return t.isEmpty ? 'text' : t;
  }

  List<Map<String, dynamic>> _buildOrderedResponses(
    Map<String, dynamic> data,
    Map<String, Map<String, dynamic>> fieldMap,
  ) {
    final rows = <Map<String, dynamic>>[];
    final formatted = data['formattedResponses'];

    if (formatted is List) {
      for (var i = 0; i < formatted.length; i++) {
        final item = formatted[i];
        if (item is! Map) continue;
        final row = Map<String, dynamic>.from(item.cast<dynamic, dynamic>());
        var fieldId =
            row['fieldId']?.toString() ??
            row['id']?.toString() ??
            row['key']?.toString();
        final rawLabel = row['label']?.toString();

        if ((fieldId == null || fieldId.isEmpty) &&
            rawLabel != null &&
            fieldMap.containsKey(rawLabel)) {
          fieldId = rawLabel;
        }

        rows.add({
          'label': _resolveLabel(
            fieldId: fieldId,
            fallbackLabel: rawLabel,
            fallbackIndex: i,
            fieldMap: fieldMap,
          ),
          'type': _resolveType(
            fieldId: fieldId,
            fallbackType: row['type']?.toString(),
            fieldMap: fieldMap,
          ),
          'value': row['value'],
          '_order': _fieldOrder(fieldId, fieldMap),
          '_fallback': i,
        });
      }
    }

    if (rows.isEmpty) {
      Map<String, dynamic> rawResponses = {};
      if (data['responses'] is Map) {
        rawResponses = Map<String, dynamic>.from(
          (data['responses'] as Map).cast<dynamic, dynamic>(),
        );
      } else {
        rawResponses = data;
      }

      final entries =
          rawResponses.entries
              .where((e) => !_responseMetaKeys.contains(e.key))
              .toList();

      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i];
        final fieldId = entry.key;
        rows.add({
          'label': _resolveLabel(
            fieldId: fieldId,
            fallbackLabel: entry.key,
            fallbackIndex: i,
            fieldMap: fieldMap,
          ),
          'type': _resolveType(
            fieldId: fieldId,
            fallbackType: null,
            fieldMap: fieldMap,
          ),
          'value': entry.value,
          '_order': _fieldOrder(fieldId, fieldMap),
          '_fallback': i,
        });
      }
    }

    rows.sort((a, b) {
      final orderA = (a['_order'] as int?) ?? (1 << 30);
      final orderB = (b['_order'] as int?) ?? (1 << 30);
      if (orderA != orderB) return orderA.compareTo(orderB);
      final fallbackA = (a['_fallback'] as int?) ?? 0;
      final fallbackB = (b['_fallback'] as int?) ?? 0;
      return fallbackA.compareTo(fallbackB);
    });

    return rows
        .map(
          (r) => {'label': r['label'], 'type': r['type'], 'value': r['value']},
        )
        .toList();
  }

  String _formatResponseValue(dynamic value) {
    if (value == null) return '(not answered)';
    if (value is List) {
      if (value.isEmpty) return '(none selected)';
      return value.join(', ');
    }
    if (value is Map) {
      final map = value;
      final parts = <String>[];
      if (map['street']?.toString().isNotEmpty == true) {
        parts.add(map['street'].toString());
      }
      if (map['street2']?.toString().isNotEmpty == true) {
        parts.add(map['street2'].toString());
      }
      final cityLine = <String>[];
      if (map['city']?.toString().isNotEmpty == true) {
        cityLine.add(map['city'].toString());
      }
      if (map['province']?.toString().isNotEmpty == true) {
        cityLine.add(map['province'].toString());
      }
      if (map['postal']?.toString().isNotEmpty == true) {
        cityLine.add(map['postal'].toString());
      }
      if (cityLine.isNotEmpty) parts.add(cityLine.join(', '));
      if (parts.isNotEmpty) return parts.join('\n');

      final generic = map.entries
          .where((e) => e.value?.toString().trim().isNotEmpty == true)
          .map((e) => '${e.key}: ${e.value}')
          .join(', ');
      return generic.isEmpty ? '(not answered)' : generic;
    }
    if (value is bool) return value ? 'Yes' : 'No';
    if (value is Timestamp) {
      return DateFormat('MMM d, yyyy • h:mm a').format(value.toDate());
    }
    final text = value.toString().trim();
    return text.isEmpty ? '(not answered)' : text;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey[100],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Responses: $pageTitle',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream:
                FirebaseFirestore.instance
                    .collection('unlistedPages')
                    .doc(pageId)
                    .snapshots(),
            builder: (context, pageSnapshot) {
              if (!pageSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final pageData = pageSnapshot.data!.data();
              final formFields =
                  (pageData?['formFields'] as List<dynamic>?) ?? [];

              // Create a map of field IDs to labels for ordering
              final fieldMap = <String, Map<String, dynamic>>{};
              for (var i = 0; i < formFields.length; i++) {
                if (formFields[i] is Map) {
                  final field = formFields[i] as Map;
                  final fieldId = field['id']?.toString() ?? '';
                  if (fieldId.isNotEmpty) {
                    fieldMap[fieldId] = {
                      'label': field['label']?.toString() ?? 'Field ${i + 1}',
                      'type': field['type']?.toString() ?? 'text',
                      'order': i,
                    };
                  }
                }
              }

              return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream:
                    FirebaseFirestore.instance
                        .collection('unlistedPages')
                        .doc(pageId)
                        .collection('responses')
                        .orderBy('submittedAt', descending: true)
                        .snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final docs = snapshot.data!.docs;

                  if (docs.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inbox, size: 64, color: Colors.grey[400]),
                          const SizedBox(height: 16),
                          Text(
                            'No responses yet',
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final doc = docs[index];
                      final data = doc.data();
                      final orderedResponses = _buildOrderedResponses(
                        data,
                        fieldMap,
                      );

                      final submittedAt = data['submittedAt'] as Timestamp?;
                      final email = data['submittedByEmail']?.toString() ?? '';
                      final name = data['submittedByName']?.toString() ?? '';

                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    radius: 16,
                                    backgroundColor: const Color(0xFF00B894),
                                    child: Text(
                                      '${index + 1}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (name.isNotEmpty || email.isNotEmpty)
                                          Text(
                                            name.isNotEmpty ? name : email,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 15,
                                            ),
                                          ),
                                        if (submittedAt != null)
                                          Text(
                                            _formatDate(submittedAt.toDate()),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey[600],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(height: 24),
                              ...orderedResponses.map((response) {
                                final label =
                                    response['label']?.toString() ?? 'Field';
                                final value = response['value'];
                                final displayValue = _formatResponseValue(
                                  value,
                                );

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.grey[50],
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.grey.shade200,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        label,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF00695C),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        displayValue,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          height: 1.4,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;

  const _StatusChip({
    required this.label,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ANALYTICS TAB
// ============================================================================
class _AnalyticsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Platform Analytics',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          _buildUserGrowth(),
          const SizedBox(height: 24),
          _buildPopularDestinations(),
          const SizedBox(height: 24),
          _buildEngagementMetrics(),
        ],
      ),
    );
  }

  Widget _buildUserGrowth() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'User Growth',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            StreamBuilder<QuerySnapshot>(
              stream:
                  FirebaseFirestore.instance
                      .collection('users')
                      .orderBy('createdAt')
                      .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const CircularProgressIndicator();
                }

                final users = snapshot.data!.docs;
                final total = users.length;

                // Count users by month
                final Map<String, int> monthlyUsers = {};
                for (var doc in users) {
                  final data = doc.data() as Map<String, dynamic>;
                  final createdAt = data['createdAt'] as Timestamp?;
                  if (createdAt != null) {
                    final date = createdAt.toDate();
                    final monthKey = DateFormat('yyyy-MM').format(date);
                    monthlyUsers[monthKey] = (monthlyUsers[monthKey] ?? 0) + 1;
                  }
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total Users: $total',
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 12),
                    ...monthlyUsers.entries.map((e) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(width: 80, child: Text(e.key)),
                            Expanded(
                              child: LinearProgressIndicator(
                                value: total > 0 ? e.value / total : 0,
                                backgroundColor: Colors.grey[200],
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFF00B894),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text('${e.value}'),
                          ],
                        ),
                      );
                    }),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPopularDestinations() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Popular Destinations',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            StreamBuilder<QuerySnapshot>(
              stream:
                  FirebaseFirestore.instance
                      .collectionGroup('trips')
                      .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const CircularProgressIndicator();
                }

                // Count destination occurrences
                final Map<String, int> destCounts = {};
                for (var doc in snapshot.data!.docs) {
                  final data = doc.data() as Map<String, dynamic>;
                  final waypoints = data['waypoints'] as List<dynamic>? ?? [];
                  for (var wp in waypoints) {
                    if (wp is Map) {
                      final name = (wp['name'] ?? '').toString().trim();
                      if (name.isNotEmpty) {
                        destCounts[name] = (destCounts[name] ?? 0) + 1;
                      }
                    }
                  }
                }

                final sorted =
                    destCounts.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value));
                final top10 = sorted.take(10).toList();

                if (top10.isEmpty) {
                  return const Text('No destination data yet');
                }

                return Column(
                  children:
                      top10.map((e) {
                        return ListTile(
                          leading: const Icon(
                            Icons.location_on,
                            color: Color(0xFF00B894),
                          ),
                          title: Text(e.key),
                          trailing: Text(
                            '${e.value} trips',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        );
                      }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEngagementMetrics() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Engagement Metrics',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            FutureBuilder<Map<String, int>>(
              future: _calculateEngagementMetrics(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const CircularProgressIndicator();
                }

                final metrics = snapshot.data!;
                return Column(
                  children: [
                    _MetricRow('Total Trips Created', metrics['totalTrips']!),
                    _MetricRow('Verified Trips', metrics['verifiedTrips']!),
                    _MetricRow('Unlisted Pages', metrics['pages']!),
                    _MetricRow('Total Users', metrics['users']!),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<Map<String, int>> _calculateEngagementMetrics() async {
    final trips =
        await FirebaseFirestore.instance.collectionGroup('trips').get();
    final verifiedTrips =
        await FirebaseFirestore.instance.collection('verifiedTrips').get();
    final pages =
        await FirebaseFirestore.instance.collection('unlistedPages').get();
    final users = await FirebaseFirestore.instance.collection('users').get();

    return {
      'totalTrips': trips.docs.length,
      'verifiedTrips': verifiedTrips.docs.length,
      'pages': pages.docs.length,
      'users': users.docs.length,
    };
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final int value;

  const _MetricRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 16)),
          Text(
            value.toString(),
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF00B894),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// PERSONAL NOTES TAB - Your personal workspace
// ============================================================================
class _PersonalNotesTab extends StatefulWidget {
  @override
  State<_PersonalNotesTab> createState() => _PersonalNotesTabState();
}

class _PersonalNotesTabState extends State<_PersonalNotesTab> {
  final _noteController = TextEditingController();
  final _titleController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _noteController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Center(child: Text('Not logged in'));
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.purple[50],
          child: Row(
            children: [
              const Icon(Icons.sticky_note_2, color: Colors.purple),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Your personal notes & tasks - accessible only to you',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => _showNewNoteDialog(context, user.uid),
                icon: const Icon(Icons.add),
                label: const Text('New Note'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream:
                FirebaseFirestore.instance
                    .collection('admins')
                    .doc(user.uid)
                    .collection('notes')
                    .orderBy('createdAt', descending: true)
                    .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final notes = snapshot.data!.docs;

              if (notes.isEmpty) {
                return const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.note, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('No notes yet. Create your first note!'),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: notes.length,
                itemBuilder: (context, index) {
                  final doc = notes[index];
                  final data = doc.data() as Map<String, dynamic>;
                  final title = data['title'] ?? 'Untitled';
                  final content = data['content'] ?? '';
                  final createdAt = data['createdAt'] as Timestamp?;
                  final isPinned = data['pinned'] == true;

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    color: isPinned ? Colors.yellow[50] : null,
                    child: ExpansionTile(
                      leading: IconButton(
                        icon: Icon(
                          isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                          color: isPinned ? Colors.orange : null,
                        ),
                        onPressed:
                            () => _togglePin(user.uid, doc.id, !isPinned),
                      ),
                      title: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        createdAt != null
                            ? DateFormat(
                              'MMM d, y h:mm a',
                            ).format(createdAt.toDate())
                            : '',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(content),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton.icon(
                                    onPressed:
                                        () => _editNote(
                                          context,
                                          user.uid,
                                          doc.id,
                                          data,
                                        ),
                                    icon: const Icon(Icons.edit, size: 16),
                                    label: const Text('Edit'),
                                  ),
                                  TextButton.icon(
                                    onPressed:
                                        () => _deleteNote(
                                          context,
                                          user.uid,
                                          doc.id,
                                          title,
                                        ),
                                    icon: const Icon(Icons.delete, size: 16),
                                    label: const Text('Delete'),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.red,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _showNewNoteDialog(BuildContext context, String uid) async {
    _titleController.clear();
    _noteController.clear();

    await showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('New Note'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _noteController,
                    decoration: const InputDecoration(
                      labelText: 'Content',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 8,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  await _saveNote(uid, null);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          ),
    );
  }

  Future<void> _editNote(
    BuildContext context,
    String uid,
    String noteId,
    Map<String, dynamic> data,
  ) async {
    _titleController.text = data['title'] ?? '';
    _noteController.text = data['content'] ?? '';

    await showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Edit Note'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _noteController,
                    decoration: const InputDecoration(
                      labelText: 'Content',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 8,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  await _saveNote(uid, noteId);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          ),
    );
  }

  Future<void> _saveNote(String uid, String? noteId) async {
    if (_titleController.text.trim().isEmpty) return;

    setState(() => _saving = true);

    try {
      final data = {
        'title': _titleController.text.trim(),
        'content': _noteController.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (noteId == null) {
        data['createdAt'] = FieldValue.serverTimestamp();
        await FirebaseFirestore.instance
            .collection('admins')
            .doc(uid)
            .collection('notes')
            .add(data);
      } else {
        await FirebaseFirestore.instance
            .collection('admins')
            .doc(uid)
            .collection('notes')
            .doc(noteId)
            .update(data);
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(const SnackBar(content: Text('Note saved')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _togglePin(String uid, String noteId, bool pinned) async {
    try {
      await FirebaseFirestore.instance
          .collection('admins')
          .doc(uid)
          .collection('notes')
          .doc(noteId)
          .update({'pinned': pinned});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _deleteNote(
    BuildContext context,
    String uid,
    String noteId,
    String title,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete Note'),
            content: Text('Delete "$title"?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      try {
        await FirebaseFirestore.instance
            .collection('admins')
            .doc(uid)
            .collection('notes')
            .doc(noteId)
            .delete();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showTryprSnackBar(const SnackBar(content: Text('Note deleted')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showTryprSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }
}

// ============================================================================
// SETTINGS TAB
// ============================================================================
class _SettingsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Admin Settings',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 24),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.backup),
                title: const Text('Backup Database'),
                subtitle: const Text('Export all data'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  ScaffoldMessenger.of(context).showTryprSnackBar(
                    const SnackBar(content: Text('Backup feature coming soon')),
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.security),
                title: const Text('Security Rules'),
                subtitle: const Text('View Firestore rules'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  // Open Firestore rules in Firebase Console
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.bug_report),
                title: const Text('Debug Mode'),
                subtitle: const Text('Enable detailed logging'),
                trailing: Switch(value: false, onChanged: (value) {}),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('About'),
                subtitle: const Text('Version 1.0.0'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  showAboutDialog(
                    context: context,
                    applicationName: 'Trypr Admin',
                    applicationVersion: '1.0.0',
                    applicationIcon: const Icon(
                      Icons.admin_panel_settings,
                      size: 48,
                      color: Color(0xFF00B894),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// EDIT USER DIALOG - Separate StatefulWidget to avoid mouse tracker issues
// ============================================================================
class _EditUserDialog extends StatefulWidget {
  final Map<String, dynamic> currentData;

  const _EditUserDialog({required this.currentData});

  @override
  State<_EditUserDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends State<_EditUserDialog> {
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _bioController;
  late String _selectedSex;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.currentData['name'] ?? '',
    );
    _emailController = TextEditingController(
      text: widget.currentData['email'] ?? '',
    );
    _bioController = TextEditingController(
      text: widget.currentData['bio'] ?? '',
    );
    _selectedSex = widget.currentData['sex'] ?? 'Not specified';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit User Details'),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email (read-only)',
                  border: OutlineInputBorder(),
                ),
                enabled: false,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _bioController,
                decoration: const InputDecoration(
                  labelText: 'Bio',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _selectedSex,
                decoration: const InputDecoration(
                  labelText: 'Sex',
                  border: OutlineInputBorder(),
                ),
                items:
                    ['Not specified', 'Male', 'Female', 'Other'].map((sex) {
                      return DropdownMenuItem(value: sex, child: Text(sex));
                    }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _selectedSex = value;
                    });
                  }
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context, {
              'name': _nameController.text,
              'email': _emailController.text,
              'bio': _bioController.text,
              'sex': _selectedSex,
            });
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6c5ce7),
          ),
          child: const Text('Save Changes'),
        ),
      ],
    );
  }
}
