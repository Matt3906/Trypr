import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/screens/trip_detail_screen.dart';

/// Screen that handles `/trip/:ownerUid/:tripId` deep links.
///
/// Access logic:
/// - **Signed-in + owner or in sharedWith** → full editing (readOnly: false)
/// - **Signed-in but not shared** → read-only if shareLinkEnabled, else join request flow
/// - **Not signed-in** → read-only if shareLinkEnabled, else prompt to sign in
class TripLinkScreen extends StatefulWidget {
  final String ownerUid;
  final String tripId;

  const TripLinkScreen({
    super.key,
    required this.ownerUid,
    required this.tripId,
  });

  @override
  State<TripLinkScreen> createState() => _TripLinkScreenState();
}

class _TripLinkScreenState extends State<TripLinkScreen> {
  bool _loading = true;
  String? _error;

  // Once resolved, store the trip data and access level so we can directly
  // render TripDetailScreen inline (no push/replace needed).
  Map<String, dynamic>? _resolvedTripData;
  bool _resolvedReadOnly = true;
  bool _resolvedPublicPreview = false;

  @override
  void initState() {
    super.initState();
    _resolveTrip();
  }

  String get _tripRefPath => 'users/${widget.ownerUid}/trips/${widget.tripId}';

  Future<void> _resolveTrip() async {
    try {
      // ignore: avoid_print
      print('TripLinkScreen: resolving $_tripRefPath');

      // Wait for Firebase Auth to settle its state (signed-in / anonymous).
      // On web the Firestore SDK queues reads behind auth resolution, so
      // without this the get() can hang indefinitely for unauthenticated users.
      try {
        await FirebaseAuth.instance.authStateChanges().first.timeout(
          const Duration(seconds: 5),
        );
      } catch (_) {
        // Timeout is fine — just means auth took too long, proceed anyway
      }

      final user = FirebaseAuth.instance.currentUser;
      // ignore: avoid_print
      print('TripLinkScreen: user=${user?.uid ?? 'null'}');

      final tripDocRef = FirebaseFirestore.instance.doc(_tripRefPath);

      DocumentSnapshot<Map<String, dynamic>> snap;
      try {
        snap = await tripDocRef.get().timeout(const Duration(seconds: 10));
        // ignore: avoid_print
        print('TripLinkScreen: doc exists=${snap.exists}');
      } catch (e) {
        // ignore: avoid_print
        print('TripLinkScreen: get() failed: $e');
        // Permission denied or timeout — user can't read this trip
        if (user == null) {
          if (mounted) {
            setState(() {
              _loading = false;
              _error = 'sign-in-required';
            });
          }
          return;
        }
        // Signed in but permission denied — offer join request
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'no-access';
          });
        }
        return;
      }

      if (!snap.exists) {
        // ignore: avoid_print
        print('TripLinkScreen: trip not found');
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'Trip not found';
          });
        }
        return;
      }

      final data = snap.data()!;
      final tripData = <String, dynamic>{...data, 'tripRef': _tripRefPath};
      final shareLinkEnabled = data['shareLinkEnabled'] == true;

      // Explicit guard for anonymous viewers so behavior doesn't depend only
      // on Firestore rules.
      if (user == null && !shareLinkEnabled) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'sign-in-required';
          });
        }
        return;
      }

      // Determine access level
      final bool hasEditAccess;
      if (user == null) {
        hasEditAccess = false;
      } else if (user.uid == widget.ownerUid) {
        hasEditAccess = true;
      } else {
        // Check if user is in sharedWith
        final sharedWith = (data['sharedWith'] as List<dynamic>?) ?? [];
        hasEditAccess = sharedWith.contains(user.uid);
      }

      // ignore: avoid_print
      print('TripLinkScreen: resolved, readOnly=${!hasEditAccess}');

      if (!mounted) return;

      // Store resolved data and rebuild — build() will render TripDetailScreen
      setState(() {
        _resolvedTripData = tripData;
        _resolvedReadOnly = !hasEditAccess;
        _resolvedPublicPreview = user == null;
        _loading = false;
      });
    } catch (e) {
      // ignore: avoid_print
      print('TripLinkScreen error: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Something went wrong: $e';
        });
      }
    }
  }

  Future<void> _sendJoinRequest() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _loading = true);

    try {
      String requesterName = (user.displayName ?? '').trim();
      if (requesterName.isEmpty) {
        final pub =
            await FirebaseFirestore.instance
                .collection('publicUsers')
                .doc(user.uid)
                .get();
        requesterName = (pub.data()?['name'] ?? '').toString().trim();
      }
      if (requesterName.isEmpty) requesterName = 'Someone';

      final joinReqId = '${widget.ownerUid}_${widget.tripId}_${user.uid}';
      final joinReqRef = FirebaseFirestore.instance
          .collection('tripJoinRequests')
          .doc(joinReqId);

      final existing = await joinReqRef.get();
      if (existing.exists) {
        final status = (existing.data()?['status'] ?? '').toString();
        if (status == 'approved') {
          // Already approved — try again
          await _resolveTrip();
          return;
        }
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'request-pending';
          });
        }
        return;
      }

      await joinReqRef.set({
        'tripRef': _tripRefPath,
        'ownerUid': widget.ownerUid,
        'tripId': widget.tripId,
        'requesterUid': user.uid,
        'requesterName': requesterName,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'request-sent';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Failed to send request: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Trip resolved successfully — render full editor for signed-in users,
    // and a lightweight preview for anonymous visitors.
    if (_resolvedTripData != null) {
      if (_resolvedPublicPreview) {
        return _buildPublicPreview(_resolvedTripData!);
      }
      return TripDetailScreen(
        docId: widget.tripId,
        data: _resolvedTripData!,
        readOnly: _resolvedReadOnly,
      );
    }

    if (_loading) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading trip…'),
            ],
          ),
        ),
      );
    }

    // Error/state screens
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _buildErrorContent(),
        ),
      ),
    );
  }

  Widget _buildPublicPreview(Map<String, dynamic> data) {
    final tripName = (data['name'] ?? 'Shared Trip').toString().trim();
    final tripTitle = tripName.isEmpty ? 'Shared Trip' : tripName;
    final startDate = (data['startDate'] ?? '').toString().trim();
    final endDate = (data['endDate'] ?? '').toString().trim();
    final totalDaysRaw = data['totalDays'];
    final int? totalDays = totalDaysRaw is num ? totalDaysRaw.toInt() : null;

    final waypointsRaw = (data['waypoints'] as List<dynamic>?) ?? const [];
    final waypoints =
        waypointsRaw.whereType<Map>().map((e) {
          final out = <String, dynamic>{};
          e.forEach((k, v) => out[k.toString()] = v);
          return out;
        }).toList();

    final subtitleParts = <String>[
      if (startDate.isNotEmpty && endDate.isNotEmpty) '$startDate to $endDate',
      if (totalDays != null && totalDays > 0)
        '$totalDays day${totalDays == 1 ? '' : 's'}',
      '${waypoints.length} stop${waypoints.length == 1 ? '' : 's'}',
    ];

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tripTitle,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitleParts.join(' • '),
                    style: const TextStyle(color: Colors.black54, fontSize: 15),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.visibility_outlined, size: 20),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'You are viewing a public preview. Sign in to request access and collaborate on this trip.',
                            style: TextStyle(height: 1.35),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Stops',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  if (waypoints.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFAFAFA),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                      ),
                      child: const Text('No stops added yet.'),
                    )
                  else
                    ...waypoints.asMap().entries.map((entry) {
                      final i = entry.key;
                      final wp = entry.value;
                      final name =
                          (wp['name'] ?? 'Stop ${i + 1}').toString().trim();
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE5E7EB)),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 14,
                              backgroundColor: const Color(0xFF111827),
                              foregroundColor: Colors.white,
                              child: Text(
                                '${i + 1}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                name.isEmpty ? 'Stop ${i + 1}' : name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      ElevatedButton.icon(
                        onPressed:
                            () => Navigator.of(context).pushNamed('/sign-in'),
                        icon: const Icon(Icons.login),
                        label: const Text('Sign in to join'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF111827),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                          shape: const StadiumBorder(),
                        ),
                      ),
                      OutlinedButton(
                        onPressed:
                            () => Navigator.of(
                              context,
                            ).pushNamed('/create-account'),
                        child: const Text('Create account'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorContent() {
    if (_error == 'sign-in-required') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 48, color: Colors.black54),
          const SizedBox(height: 16),
          const Text(
            'Sign in to view this trip',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'This trip requires a Trypr account to view.',
            style: TextStyle(color: Colors.grey[600]),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(context).pushNamed('/sign-in'),
            icon: const Icon(Icons.login),
            label: const Text('Sign in'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF111827),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: const StadiumBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pushNamed('/create-account'),
            child: const Text('Create an account'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Go back'),
          ),
        ],
      );
    }

    if (_error == 'no-access') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 48, color: Colors.black54),
          const SizedBox(height: 16),
          const Text(
            'Access required',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'You don\'t have access to this trip yet. Send a request to join!',
            style: TextStyle(color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _sendJoinRequest,
            icon: const Icon(Icons.person_add),
            label: const Text('Request to join'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF111827),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: const StadiumBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Go back'),
          ),
        ],
      );
    }

    if (_error == 'request-sent' || _error == 'request-pending') {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.hourglass_top, size: 48, color: Colors.amber),
          const SizedBox(height: 16),
          Text(
            _error == 'request-sent'
                ? 'Request sent!'
                : 'Request already pending',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'The trip owner needs to approve your request. Once approved, '
            'this trip will appear in your Shared Trips.',
            style: TextStyle(color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pushNamed('/my-trips'),
            child: const Text('Go to My Trips'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Go back'),
          ),
        ],
      );
    }

    // Generic error
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 48, color: Colors.red),
        const SizedBox(height: 16),
        Text(
          _error ?? 'Something went wrong',
          style: const TextStyle(fontSize: 16),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Go back'),
        ),
      ],
    );
  }
}
