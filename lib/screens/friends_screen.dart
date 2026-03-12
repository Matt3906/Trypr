import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/theme/app_theme.dart';
import 'package:trypr/widgets/top_taskbar.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  User? get _me => FirebaseAuth.instance.currentUser;

  final Map<String, Map<String, dynamic>> _userCache = {};

  Stream<QuerySnapshot<Map<String, dynamic>>>? _incomingRequestsStream() {
    final m = _me;
    if (m == null) return null;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(m.uid)
        .collection('friendRequests')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>>? _myDocStream() {
    final m = _me;
    if (m == null) return null;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(m.uid)
        .snapshots();
  }

  Future<void> _showAddFriendDialog(BuildContext context) async {
    final ctl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Add friend (email)'),
          content: TextField(
            controller: ctl,
            decoration: const InputDecoration(labelText: 'Friend email'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
            TextButton(
              onPressed: () async {
                final me = _me;
                if (me == null) return;
                final target = ctl.text.trim();
                if (target.isEmpty) return;
                try {
                  final q =
                      await FirebaseFirestore.instance
                          .collection('users')
                          .where('email', isEqualTo: target.toLowerCase())
                          .limit(1)
                          .get();
                  if (q.docs.isEmpty) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showTryprSnackBar(
                      const SnackBar(content: Text('No user found')),
                    );
                    return;
                  }
                  final doc = q.docs.first;
                  final targetUid = doc.id;
                  await FirebaseFirestore.instance
                      .collection('users')
                      .doc(targetUid)
                      .collection('friendRequests')
                      .add({
                        'fromUid': me.uid,
                        'fromEmail': me.email ?? '',
                        'fromName':
                            (me.displayName != null &&
                                    me.displayName!.isNotEmpty)
                                ? me.displayName
                                : (me.email ?? me.uid),
                        'createdAt': FieldValue.serverTimestamp(),
                        'status': 'pending',
                      });
                  if (!mounted) return;
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showTryprSnackBar(
                    const SnackBar(content: Text('Friend request sent')),
                  );
                } catch (err) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showTryprSnackBar(
                    SnackBar(content: Text('Failed to send request: $err')),
                  );
                }
              },
              child: const Text('Send'),
            ),
          ],
        );
      },
    );
    ctl.dispose();
  }

  Future<void> _acceptRequest(String reqId, Map<String, dynamic> data) async {
    final me = _me;
    if (me == null) return;
    final fromUid = data['fromUid'] as String?;
    final fromEmail = data['fromEmail'] as String? ?? '';
    final fromName = data['fromName'] as String? ?? '';

    final meRef = FirebaseFirestore.instance.collection('users').doc(me.uid);

    try {
      if (fromUid == null || fromUid.isEmpty) {
        await meRef.update({
          'friends': FieldValue.arrayUnion([
            {'uid': '', 'displayName': fromName, 'email': fromEmail},
          ]),
        });
        await meRef.collection('friendRequests').doc(reqId).delete();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(content: Text('Friend request accepted')),
        );
        return;
      }

      final otherRef = FirebaseFirestore.instance
          .collection('users')
          .doc(fromUid);
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final meSnap = await tx.get(meRef);
        final otherSnap = await tx.get(otherRef);
        final meData = meSnap.data() ?? {};
        final otherData = otherSnap.data() ?? {};

        final canonicalFromName =
            fromName.isNotEmpty
                ? fromName
                : (fromEmail.isNotEmpty ? fromEmail : fromUid);
        final canonicalMyName =
            (me.displayName ?? '').isNotEmpty
                ? me.displayName!
                : (me.email ?? me.uid);

        final meFriends = List.from(meData['friends'] ?? []);
        if (!meFriends.any(
          (e) => (e is Map && e['uid'] == fromUid) || e == fromUid,
        )) {
          meFriends.add({
            'uid': fromUid,
            'displayName': canonicalFromName,
            'email': fromEmail,
          });
        }
        tx.set(meRef, {'friends': meFriends}, SetOptions(merge: true));

        final otherFriends = List.from(otherData['friends'] ?? []);
        if (!otherFriends.any(
          (e) => (e is Map && e['uid'] == me.uid) || e == me.uid,
        )) {
          otherFriends.add({
            'uid': me.uid,
            'displayName': canonicalMyName,
            'email': me.email ?? '',
          });
        }
        tx.set(otherRef, {'friends': otherFriends}, SetOptions(merge: true));

        tx.delete(meRef.collection('friendRequests').doc(reqId));
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Friend request accepted')),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        SnackBar(content: Text('Failed to accept request: $err')),
      );
    }
  }

  Future<void> _declineRequest(String reqId) async {
    final me = _me;
    if (me == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(me.uid)
          .collection('friendRequests')
          .doc(reqId)
          .delete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Friend request declined')),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        SnackBar(content: Text('Failed to decline request: $err')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final reqStream = _incomingRequestsStream();
    final myStream = _myDocStream();
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      backgroundColor: TryprColors.background,
      body: Padding(
        padding: const EdgeInsets.all(TryprSpacing.lg),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Friends',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                ),
                PrimaryButton(
                  label: 'Add Friend',
                  icon: Icons.person_add_outlined,
                  onPressed: () => _showAddFriendDialog(context),
                ),
              ],
            ),
            const SizedBox(height: TryprSpacing.xl),
            SoftCard(
              padding: const EdgeInsets.all(TryprSpacing.lg),
              child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>?>(
                stream: myStream,
                builder: (ctx, snap) {
                  if (!snap.hasData) {
                    return const SizedBox(
                      height: 120,
                      child: Center(
                        child: CircularProgressIndicator(
                          color: TryprColors.primary,
                        ),
                      ),
                    );
                  }
                  final data = snap.data!.data() ?? {};
                  final friendsRaw = data['friends'] as List<dynamic>? ?? [];
                  if (friendsRaw.isEmpty) {
                    return const SizedBox(
                      height: 120,
                      child: Center(child: Text('No friends yet')),
                    );
                  }
                  final friends =
                      friendsRaw
                          .map<Map<String, dynamic>>(
                            (f) =>
                                f is Map
                                    ? Map<String, dynamic>.from(f)
                                    : {'id': f.toString()},
                          )
                          .toList();
                  return SizedBox(
                    height: 160,
                    child: ListView.separated(
                      itemCount: friends.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx2, i) => _friendTile(friends[i]),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Friend Requests',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>?>(
                    stream: reqStream,
                    builder: (ctx, snap) {
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final docs = snap.data!.docs;
                      if (docs.isEmpty) {
                        return const Center(
                          child: Text('No incoming requests'),
                        );
                      }
                      return ListView.separated(
                        itemCount: docs.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx2, i) {
                          final doc = docs[i];
                          final d = doc.data();
                          final fromName =
                              d['fromName'] ?? d['fromEmail'] ?? 'Someone';
                          final fromEmail = d['fromEmail'] ?? '';
                          return ListTile(
                            title: Text(fromName),
                            subtitle: Text(fromEmail),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.check),
                                  color: Colors.green,
                                  onPressed: () => _acceptRequest(doc.id, d),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close),
                                  color: Colors.red,
                                  onPressed: () => _declineRequest(doc.id),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _friendTile(Map<String, dynamic> f) {
    final uid = (f['uid'] ?? f['id'])?.toString();
    final email = (f['email'] ?? '')?.toString() ?? '';
    final rawName = f['displayName'] ?? f['name'];
    final nameStr =
        rawName is String && rawName.trim().isNotEmpty ? rawName : null;

    Widget actionsForUid(String? targetUid) {
      if (targetUid == null || targetUid.isEmpty) {
        return const SizedBox.shrink();
      }
      return PopupMenuButton<String>(
        onSelected: (val) {
          if (val == 'remove') _confirmAndRemove(targetUid, f);
        },
        itemBuilder:
            (_) => const [
              PopupMenuItem(value: 'remove', child: Text('Remove friend')),
            ],
      );
    }

    if (nameStr != null) {
      return ListTile(
        leading: const Icon(Icons.person),
        title: Text(nameStr),
        subtitle: Text(email),
        trailing: actionsForUid(uid),
      );
    }
    if (uid == null || uid.isEmpty) {
      return ListTile(
        leading: const Icon(Icons.person),
        title: Text(email.isNotEmpty ? email : 'User'),
        subtitle: Text(email),
      );
    }

    final cached = _userCache[uid];
    if (cached != null) {
      final resolved =
          cached['displayName'] ?? cached['name'] ?? cached['email'] ?? uid;
      final city = (cached['city'] ?? cached['location'] ?? '').toString();
      return ListTile(
        leading: const Icon(Icons.person),
        title: Text(resolved.toString()),
        subtitle: Text(
          '${(cached['email'] ?? email).toString()}${city.isNotEmpty ? ' • $city' : ''}',
        ),
        trailing: actionsForUid(uid),
      );
    }

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future:
          FirebaseFirestore.instance.collection('publicUsers').doc(uid).get(),
      builder: (ctx, snap) {
        if (snap.hasData && snap.data!.exists) {
          final data = snap.data!.data() ?? <String, dynamic>{};
          _userCache[uid] = Map<String, dynamic>.from(data);
          final resolved =
              data['displayName'] ?? data['name'] ?? data['email'] ?? uid;
          final city = (data['city'] ?? data['location'] ?? '').toString();
          return ListTile(
            leading: const Icon(Icons.person),
            title: Text(resolved.toString()),
            subtitle: Text(
              '${(data['email'] ?? email).toString()}${city.isNotEmpty ? ' • $city' : ''}',
            ),
            trailing: actionsForUid(uid),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const ListTile(
            leading: Icon(Icons.person),
            title: Text('Loading...'),
            subtitle: SizedBox(
              height: 8,
              width: 8,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return ListTile(
          leading: const Icon(Icons.person),
          title: Text(email.isNotEmpty ? email : uid),
          subtitle: Text(email),
          trailing: actionsForUid(uid),
        );
      },
    );
  }

  Future<void> _confirmAndRemove(
    String targetUid,
    Map<String, dynamic> entry,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Remove friend'),
            content: const Text('Are you sure you want to remove this friend?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Remove'),
              ),
            ],
          ),
    );
    if (ok == true) await _removeFriendByUid(targetUid);
  }

  Future<void> _removeFriendByUid(String targetUid) async {
    final me = _me;
    if (me == null || targetUid.isEmpty) return;
    final meRef = FirebaseFirestore.instance.collection('users').doc(me.uid);
    final otherRef = FirebaseFirestore.instance
        .collection('users')
        .doc(targetUid);
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final meSnap = await tx.get(meRef);
        final otherSnap = await tx.get(otherRef);
        final meData = meSnap.data() ?? <String, dynamic>{};
        final otherData = otherSnap.data() ?? <String, dynamic>{};
        final friends = List.from(meData['friends'] ?? []);
        final newFriends =
            friends.where((e) {
              try {
                final u =
                    (e is Map && e['uid'] != null)
                        ? e['uid'].toString()
                        : e.toString();
                return u != targetUid;
              } catch (_) {
                return true;
              }
            }).toList();
        tx.update(meRef, {'friends': newFriends});

        if (otherSnap.exists) {
          final otherFriends = List.from(otherData['friends'] ?? []);
          final newOther =
              otherFriends.where((e) {
                try {
                  final u =
                      (e is Map && e['uid'] != null)
                          ? e['uid'].toString()
                          : e.toString();
                  return u != me.uid;
                } catch (_) {
                  return true;
                }
              }).toList();
          tx.update(otherRef, {'friends': newOther});
        }
      });
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(const SnackBar(content: Text('Friend removed')));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showTryprSnackBar(
        SnackBar(content: Text('Failed to remove friend: $err')),
      );
    }
  }
}
