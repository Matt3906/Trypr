import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode;
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:flutter/services.dart';

/// Unified share-trip dialog used across the app.
///
/// Features:
/// - Share with friends (checkbox list) → adds to `sharedWith` + inbox
/// - Copy shareable link (clean `/trip/ownerUid/tripId` URL)
/// - Link requests management (owner only)
///
/// Friends who are shared-to get immediate full editing access because
/// their UID is added to `sharedWith` on the trip doc.
class ShareTripDialog extends StatefulWidget {
  /// Firestore path to the trip document, e.g. `users/{uid}/trips/{id}`.
  final String tripRefPath;

  /// The trip document ID.
  final String tripId;

  /// Display name of the trip.
  final String tripName;

  const ShareTripDialog({
    super.key,
    required this.tripRefPath,
    required this.tripId,
    required this.tripName,
  });

  /// Convenience method to show the dialog.
  static Future<void> show(
    BuildContext context, {
    required String tripRefPath,
    required String tripId,
    required String tripName,
  }) {
    return showDialog<void>(
      context: context,
      builder:
          (_) => ShareTripDialog(
            tripRefPath: tripRefPath,
            tripId: tripId,
            tripName: tripName,
          ),
    );
  }

  @override
  State<ShareTripDialog> createState() => _ShareTripDialogState();
}

class _ShareTripDialogState extends State<ShareTripDialog> {
  User? get _me => FirebaseAuth.instance.currentUser;
  late final DocumentReference<Map<String, dynamic>> _tripRef;
  late final String _ownerUid;
  bool get _isOwner => _me != null && _ownerUid == _me!.uid;

  List<Map<String, dynamic>> _friends = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _sharing = false;
  bool _linkCopied = false;

  @override
  void initState() {
    super.initState();
    _tripRef = FirebaseFirestore.instance.doc(widget.tripRefPath);
    _ownerUid = _extractOwnerUid(widget.tripRefPath);
    _loadFriends();
  }

  String _extractOwnerUid(String path) {
    try {
      final p = path.split('/');
      if (p.length >= 2 && p[0] == 'users') return p[1];
    } catch (_) {}
    return '';
  }

  Future<void> _loadFriends() async {
    final me = _me;
    if (me == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final meDoc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(me.uid)
              .get();
      final friendsRaw = meDoc.data()?['friends'] as List<dynamic>? ?? [];
      _friends =
          friendsRaw.map<Map<String, dynamic>>((f) {
            if (f is Map) return Map<String, dynamic>.from(f);
            return {'id': f.toString()};
          }).toList();
    } catch (e) {
      if (kDebugMode) print('ShareTripDialog: load friends failed: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _shareWithSelected() async {
    final me = _me;
    if (me == null || _selected.isEmpty) return;
    setState(() => _sharing = true);

    try {
      // Add selected UIDs to sharedWith on the trip doc (gives them write access)
      if (_isOwner) {
        await _tripRef.update({
          'sharedWith': FieldValue.arrayUnion(_selected.toList()),
        });
      }

      // Create sharedTrips inbox docs for each recipient
      final List<String> failed = [];
      for (final uid in _selected) {
        try {
          final dest = FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('sharedTrips')
              .doc(widget.tripId);
          await dest.set({
            'ownerUid': _ownerUid.isNotEmpty ? _ownerUid : me.uid,
            'ownerName': me.displayName ?? me.email ?? me.uid,
            'tripRef': widget.tripRefPath,
            'tripName': widget.tripName,
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (e) {
          failed.add(uid);
          if (kDebugMode) {
            print('ShareTripDialog: inbox write for $uid failed: $e');
          }
        }
      }

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(
            content: Text(
              failed.isEmpty
                  ? 'Trip shared with ${_selected.length} friend${_selected.length > 1 ? 's' : ''}'
                  : 'Shared with some failures: ${failed.join(', ')}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Share failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _copyShareLink() async {
    final origin = kIsWeb ? Uri.base.origin : 'https://trypr.co';
    final link = '$origin/trip/$_ownerUid/${widget.tripId}';
    await Clipboard.setData(ClipboardData(text: link));

    // Enable shareLinkEnabled so Firestore rules allow public reads
    try {
      await _tripRef.update({'shareLinkEnabled': true});
    } catch (_) {}

    if (mounted) {
      setState(() => _linkCopied = true);
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Share link copied to clipboard')),
      );
    }
  }

  Future<void> _approveJoinRequest({
    required String requestId,
    required String requesterUid,
    required String requesterName,
  }) async {
    final me = _me;
    if (me == null) return;

    final tripName = widget.tripName;

    // Add requester to sharedWith
    await _tripRef.update({
      'sharedWith': FieldValue.arrayUnion([requesterUid]),
    });

    // Create inbox doc for them
    final dest = FirebaseFirestore.instance
        .collection('users')
        .doc(requesterUid)
        .collection('sharedTrips')
        .doc(widget.tripId);
    await dest.set({
      'ownerUid': _ownerUid,
      'ownerName': me.displayName ?? me.email ?? me.uid,
      'tripRef': widget.tripRefPath,
      'tripName': tripName,
      'createdAt': FieldValue.serverTimestamp(),
      'sharedFrom': me.displayName ?? me.email ?? me.uid,
    }, SetOptions(merge: true));

    // Update request status
    await FirebaseFirestore.instance
        .collection('tripJoinRequests')
        .doc(requestId)
        .update({
          'status': 'approved',
          'handledAt': FieldValue.serverTimestamp(),
        });
  }

  Future<void> _denyJoinRequest(String requestId) async {
    await FirebaseFirestore.instance
        .collection('tripJoinRequests')
        .doc(requestId)
        .update({
          'status': 'denied',
          'handledAt': FieldValue.serverTimestamp(),
        });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Share trip'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SizedBox(
          width: double.maxFinite,
          child:
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ── Copy link section ──
                        _buildCopyLinkSection(),
                        const SizedBox(height: 16),
                        const Divider(height: 1),
                        const SizedBox(height: 16),

                        // ── Friends section ──
                        const Text(
                          'Share with friends',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Friends get full editing access immediately.',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildFriendsList(),

                        // ── Link requests (owner only) ──
                        if (_isOwner) ...[
                          const SizedBox(height: 16),
                          const Divider(height: 1),
                          const SizedBox(height: 16),
                          _buildJoinRequestsSection(),
                        ],
                      ],
                    ),
                  ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (_friends.isNotEmpty)
          TextButton(
            onPressed:
                _sharing || _selected.isEmpty ? null : _shareWithSelected,
            child:
                _sharing
                    ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : Text('Share (${_selected.length})'),
          ),
      ],
    );
  }

  Widget _buildCopyLinkSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Share via link',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        const SizedBox(height: 4),
        Text(
          'Anyone with the link can view. Signed-in users who are shared-to can edit.',
          style: TextStyle(color: Colors.grey[600], fontSize: 12),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _copyShareLink,
          icon: Icon(_linkCopied ? Icons.check : Icons.link),
          label: Text(_linkCopied ? 'Link copied!' : 'Copy share link'),
        ),
      ],
    );
  }

  Widget _buildFriendsList() {
    if (_friends.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.people_outline, color: Colors.grey[400]),
            const SizedBox(width: 8),
            Text(
              'No friends yet. Add friends from your account.',
              style: TextStyle(color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: (_friends.length * 56.0).clamp(56.0, 240.0),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _friends.length,
        itemBuilder: (ctx, i) {
          final f = _friends[i];
          final uid = (f['uid'] ?? f['id'])?.toString();
          final label =
              (f['displayName'] ?? f['name'] ?? f['email'] ?? uid ?? 'Friend')
                  .toString();
          final email = (f['email'] ?? '').toString();
          return CheckboxListTile(
            value: uid != null && _selected.contains(uid),
            onChanged: (v) {
              if (uid == null) return;
              setState(() {
                if (v == true) {
                  _selected.add(uid);
                } else {
                  _selected.remove(uid);
                }
              });
            },
            title: Text(label),
            subtitle: email.isNotEmpty ? Text(email) : null,
            dense: true,
          );
        },
      ),
    );
  }

  Widget _buildJoinRequestsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Link requests',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 160,
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream:
                FirebaseFirestore.instance
                    .collection('tripJoinRequests')
                    .where('tripRef', isEqualTo: widget.tripRefPath)
                    .snapshots(),
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: Text('Loading requests…'));
              }
              final docs = snap.data?.docs ?? const [];
              final pending =
                  docs
                      .where(
                        (d) => (d.data()['status'] ?? 'pending') == 'pending',
                      )
                      .toList();
              if (pending.isEmpty) {
                return Center(
                  child: Text(
                    'No pending requests',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                );
              }
              return ListView.separated(
                itemCount: pending.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx2, idx) {
                  final doc = pending[idx];
                  final data = doc.data();
                  final requesterUid = (data['requesterUid'] ?? '').toString();
                  final requesterName =
                      (data['requesterName'] ??
                              data['requesterEmail'] ??
                              requesterUid)
                          .toString();
                  return ListTile(
                    dense: true,
                    title: Text(requesterName),
                    subtitle: Text(
                      requesterUid,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () async {
                            try {
                              await _approveJoinRequest(
                                requestId: doc.id,
                                requesterUid: requesterUid,
                                requesterName: requesterName,
                              );
                              if (mounted) {
                                ScaffoldMessenger.of(context).showTryprSnackBar(
                                  const SnackBar(
                                    content: Text('Request approved'),
                                  ),
                                );
                              }
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showTryprSnackBar(
                                  SnackBar(content: Text('Approve failed: $e')),
                                );
                              }
                            }
                          },
                          child: const Text('Approve'),
                        ),
                        TextButton(
                          onPressed: () async {
                            try {
                              await _denyJoinRequest(doc.id);
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showTryprSnackBar(
                                  SnackBar(content: Text('Deny failed: $e')),
                                );
                              }
                            }
                          },
                          child: const Text('Deny'),
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
}
