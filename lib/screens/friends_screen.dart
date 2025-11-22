import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/widgets/top_taskbar.dart';

/// Clean, single-file Friends screen.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({Key? key}) : super(key: key);

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  User? get _me => FirebaseAuth.instance.currentUser;

  // Cache user docs by uid to fill missing display names for friends.
  final Map<String, Map<String, dynamic>> _userCache = {};

  Stream<DocumentSnapshot<Map<String, dynamic>>>? _myDocStream() {
    final m = _me;
    if (m == null) return null;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(m.uid)
        .snapshots();
  }

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

  Future<void> _acceptRequest(String reqId, Map<String, dynamic> data) async {
    final me = _me;
    if (me == null) return;
    final fromUid = data['fromUid'] as String?;
    final fromEmail = data['fromEmail'] as String? ?? '';
    final fromName = data['fromName'] as String? ?? '';

    try {
      final meRef = FirebaseFirestore.instance.collection('users').doc(me.uid);
      await meRef.update({
        'friends': FieldValue.arrayUnion([
          {'uid': fromUid ?? '', 'displayName': fromName, 'email': fromEmail},
        ]),
      });
      final reqRef = meRef.collection('friendRequests').doc(reqId);
      await reqRef.delete();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Friend request accepted')));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to accept request: $err')));
    }
  }

  Future<void> _declineRequest(String reqId) async {
    final me = _me;
    if (me == null) return;
    try {
      final reqRef = FirebaseFirestore.instance
          .collection('users')
          .doc(me.uid)
          .collection('friendRequests')
          .doc(reqId);
      await reqRef.delete();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Friend request declined')));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to decline request: $err')),
      );
    }
  }

  Future<void> _showAddFriendDialog(BuildContext context) async {
    final emailCtl = TextEditingController();
    List<Map<String, dynamic>> foundCandidates = [];
    bool isLoading = false;
    bool showDebug = false;
    String debugOutput = '';

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setState2) {
            Future<QuerySnapshot<T>> _retryQuery<T>(
              Future<QuerySnapshot<T>> Function() fn, {
              int attempts = 3,
            }) async {
              var attempt = 0;
              while (true) {
                try {
                  return await fn();
                } catch (e) {
                  attempt++;
                  if (attempt >= attempts) rethrow;
                  final wait = Duration(
                    milliseconds: 300 * (1 << (attempt - 1)),
                  );
                  await Future.delayed(wait);
                }
              }
            }

            Future<void> doSearch() async {
              final raw = emailCtl.text.trim();
              final q = raw.toLowerCase();
              if (q.isEmpty) return;
              setState2(() {
                isLoading = true;
                showDebug = false;
                debugOutput = '';
              });
              try {
                // exact email lookup
                final emailSnap = await _retryQuery(
                  () =>
                      FirebaseFirestore.instance
                          .collection('users')
                          .where('email', isEqualTo: q)
                          .limit(1)
                          .get(),
                );
                final meUid = FirebaseAuth.instance.currentUser?.uid;
                if (emailSnap.docs.isNotEmpty) {
                  final d = emailSnap.docs.first;
                  if (d.id == meUid) {
                    foundCandidates = [];
                  } else {
                    final map = Map<String, dynamic>.from(d.data());
                    map['uid'] = d.id;
                    foundCandidates = [map];
                  }
                } else {
                  // fallback to displayNameLower prefix search
                  final prefix = q;
                  final end = '$prefix\uf8ff';
                  final nameSnap = await _retryQuery(
                    () =>
                        FirebaseFirestore.instance
                            .collection('users')
                            .where(
                              'displayNameLower',
                              isGreaterThanOrEqualTo: prefix,
                            )
                            .where('displayNameLower', isLessThan: end)
                            .limit(10)
                            .get(),
                  );
                  foundCandidates =
                      nameSnap.docs.where((d) => d.id != meUid).map((d) {
                        final m = Map<String, dynamic>.from(d.data());
                        m['uid'] = d.id;
                        return m;
                      }).toList();
                }
              } catch (err) {
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Search failed (check network / rules)'),
                    ),
                  );
                foundCandidates = [];
              } finally {
                setState2(() => isLoading = false);
              }
            }

            Future<void> doDebug() async {
              final raw = emailCtl.text.trim();
              final q = raw.toLowerCase();
              if (q.isEmpty) return;
              setState2(() {
                isLoading = true;
                showDebug = false;
                debugOutput = '';
              });
              try {
                final emailSnap = await _retryQuery(
                  () =>
                      FirebaseFirestore.instance
                          .collection('users')
                          .where('email', isEqualTo: q)
                          .limit(10)
                          .get(),
                );
                final prefix = q;
                final end = '$prefix\uf8ff';
                final nameSnap = await _retryQuery(
                  () =>
                      FirebaseFirestore.instance
                          .collection('users')
                          .where(
                            'displayNameLower',
                            isGreaterThanOrEqualTo: prefix,
                          )
                          .where('displayNameLower', isLessThan: end)
                          .limit(10)
                          .get(),
                );
                final meUid = FirebaseAuth.instance.currentUser?.uid;
                final emailDocs =
                    emailSnap.docs.where((d) => d.id != meUid).toList();
                final nameDocs =
                    nameSnap.docs.where((d) => d.id != meUid).toList();
                final out = StringBuffer();
                out.writeln('EmailQuery docs: ${emailDocs.length}');
                for (var d in emailDocs) {
                  out.writeln(' - id=${d.id} data=${d.data()}');
                }
                out.writeln('NameQuery docs: ${nameDocs.length}');
                for (var d in nameDocs) {
                  out.writeln(' - id=${d.id} data=${d.data()}');
                }
                setState2(() {
                  showDebug = true;
                  debugOutput = out.toString();
                });
              } catch (err, st) {
                setState2(() {
                  showDebug = true;
                  debugOutput = 'Error: $err\n$st';
                });
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Debug search failed: $err')),
                  );
              } finally {
                setState2(() => isLoading = false);
              }
            }

            return AlertDialog(
              title: const Text('Add friend (email or name)'),
              content: SizedBox(
                width: 540,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: emailCtl,
                      decoration: const InputDecoration(
                        labelText: 'Friend email or name',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: isLoading ? null : doSearch,
                          icon: const Icon(Icons.search),
                          label: const Text('Search'),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: isLoading ? null : doDebug,
                          icon: const Icon(Icons.bug_report),
                          label: const Text('Debug'),
                        ),
                        const SizedBox(width: 12),
                        if (isLoading)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (foundCandidates.isEmpty)
                      const Text('No user found yet')
                    else
                      Column(
                        children: [
                          Text('Found ${foundCandidates.length} result(s)'),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 220,
                            child: ListView.separated(
                              itemCount: foundCandidates.length,
                              separatorBuilder:
                                  (_, __) => const Divider(height: 1),
                              itemBuilder: (ctx3, idx) {
                                final fu = foundCandidates[idx];
                                final title =
                                    fu['name'] ??
                                    fu['displayName'] ??
                                    fu['email'] ??
                                    'User';
                                final email = fu['email'] ?? '';
                                return ListTile(
                                  leading: const Icon(Icons.person),
                                  title: Text(title),
                                  subtitle: Text(email),
                                  trailing: Builder(
                                    builder: (ctxBtn) {
                                      final targetUid = fu['uid'] as String?;
                                      final me =
                                          FirebaseAuth.instance.currentUser;
                                      final isSelf =
                                          me != null && targetUid == me.uid;
                                      return ElevatedButton(
                                        onPressed:
                                            isSelf
                                                ? null
                                                : () async {
                                                  if (me == null ||
                                                      targetUid == null)
                                                    return;
                                                  if (targetUid == me.uid) {
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                          'You cannot send a friend request to yourself',
                                                        ),
                                                      ),
                                                    );
                                                    return;
                                                  }
                                                  try {
                                                    final pending =
                                                        await FirebaseFirestore
                                                            .instance
                                                            .collection('users')
                                                            .doc(targetUid)
                                                            .collection(
                                                              'friendRequests',
                                                            )
                                                            .where(
                                                              'fromUid',
                                                              isEqualTo: me.uid,
                                                            )
                                                            .limit(1)
                                                            .get();
                                                    if (pending
                                                        .docs
                                                        .isNotEmpty) {
                                                      if (!mounted) return;
                                                      ScaffoldMessenger.of(
                                                        context,
                                                      ).showSnackBar(
                                                        const SnackBar(
                                                          content: Text(
                                                            'Friend request already sent',
                                                          ),
                                                        ),
                                                      );
                                                      return;
                                                    }
                                                    final req = {
                                                      'fromUid': me.uid,
                                                      'fromEmail':
                                                          me.email ?? '',
                                                      'fromName':
                                                          me.displayName ?? '',
                                                      'createdAt':
                                                          FieldValue.serverTimestamp(),
                                                      'status': 'pending',
                                                    };
                                                    await FirebaseFirestore
                                                        .instance
                                                        .collection('users')
                                                        .doc(targetUid)
                                                        .collection(
                                                          'friendRequests',
                                                        )
                                                        .add(req);
                                                    if (!mounted) return;
                                                    Navigator.of(ctx2).pop();
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      const SnackBar(
                                                        content: Text(
                                                          'Friend request sent',
                                                        ),
                                                      ),
                                                    );
                                                  } catch (err) {
                                                    if (!mounted) return;
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          'Failed to send request: $err',
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                },
                                        child: Text(isSelf ? 'You' : 'Send'),
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    if (showDebug) ...[
                      const SizedBox(height: 12),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 180),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black12,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            debugOutput,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx2).pop(),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );

    emailCtl.dispose();
  }

  // Render a friend row. If the friend entry lacks a display name, attempt
  // to fetch the user's document and cache it so the UI shows a name.
  Widget _friendTile(Map<String, dynamic> f) {
    final uid = (f['uid'] ?? f['id'])?.toString();
    final email = (f['email'] ?? '') as String;
    final rawName = f['displayName'] ?? f['name'];
    final nameStr =
        rawName is String && rawName.trim().isNotEmpty ? rawName : null;

    Widget actionsForUid(String? targetUid, Map<String, dynamic> entry) {
      if (targetUid == null || targetUid.isEmpty)
        return const SizedBox.shrink();
      return PopupMenuButton<String>(
        onSelected: (val) {
          if (val == 'remove') {
            _confirmAndRemove(targetUid, entry);
          } else if (val == 'block') {
            _confirmAndBlock(targetUid, entry);
          }
        },
        itemBuilder:
            (_) => const [
              PopupMenuItem(value: 'remove', child: Text('Remove friend')),
              PopupMenuItem(value: 'block', child: Text('Block user')),
            ],
      );
    }

    if (nameStr != null) {
      return ListTile(
        leading: const Icon(Icons.person),
        title: Text(nameStr),
        subtitle: Text(email),
        trailing: actionsForUid(uid, f),
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
      return ListTile(
        leading: const Icon(Icons.person),
        title: Text(resolved.toString()),
        subtitle: Text((cached['email'] ?? email).toString()),
        trailing: actionsForUid(uid, f),
      );
    }

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
      builder: (ctx, snap) {
        if (snap.hasData && snap.data!.exists) {
          final data = snap.data!.data() ?? <String, dynamic>{};
          _userCache[uid] = Map<String, dynamic>.from(data);
          final resolved =
              data['displayName'] ?? data['name'] ?? data['email'] ?? uid;
          return ListTile(
            leading: const Icon(Icons.person),
            title: Text(resolved.toString()),
            subtitle: Text((data['email'] ?? email).toString()),
            trailing: actionsForUid(uid, f),
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
          trailing: actionsForUid(uid, f),
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
    if (ok == true) {
      await _removeFriendByUid(targetUid);
    }
  }

  Future<void> _confirmAndBlock(
    String targetUid,
    Map<String, dynamic> entry,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Block user'),
            content: const Text(
              'Blocking will remove the user from your friends and prevent future requests. Continue?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Block'),
              ),
            ],
          ),
    );
    if (ok == true) {
      await _blockFriendByUid(targetUid, entry);
    }
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

        // Also remove me from the other user's friends list if present
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
      ).showSnackBar(const SnackBar(content: Text('Friend removed')));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to remove friend: $err')));
    }
  }

  Future<void> _blockFriendByUid(
    String targetUid,
    Map<String, dynamic> entry,
  ) async {
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

        // Build block entry
        String bName = (entry['displayName'] ?? entry['name'] ?? '').toString();
        String bEmail = (entry['email'] ?? '').toString();
        if (bName.isEmpty && otherSnap.exists) {
          final od = otherSnap.data() ?? <String, dynamic>{};
          bName = (od['displayName'] ?? od['name'] ?? '').toString();
          bEmail = (od['email'] ?? bEmail).toString();
        }

        final blocked = List.from(meData['blocked'] ?? []);
        final already = blocked.any((e) {
          try {
            final u =
                (e is Map && e['uid'] != null)
                    ? e['uid'].toString()
                    : e.toString();
            return u == targetUid;
          } catch (_) {
            return false;
          }
        });
        if (!already) {
          blocked.add({
            'uid': targetUid,
            'displayName': bName,
            'email': bEmail,
            'createdAt': FieldValue.serverTimestamp(),
          });
        }

        tx.update(meRef, {'friends': newFriends, 'blocked': blocked});

        // Also remove me from the other user's friends list if present
        if (otherSnap.exists) {
          final otherData = otherSnap.data() ?? <String, dynamic>{};
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
      ).showSnackBar(const SnackBar(content: Text('User blocked')));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to block user: $err')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final myStream = _myDocStream();
    final reqStream = _incomingRequestsStream();
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Friends',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () => _showAddFriendDialog(context),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Add friend'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: StreamBuilder<
                          DocumentSnapshot<Map<String, dynamic>>?
                        >(
                          stream: myStream,
                          builder: (ctx, snap) {
                            if (!snap.hasData)
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            final data =
                                snap.data!.data() ?? <String, dynamic>{};
                            final friendsRaw =
                                data['friends'] as List<dynamic>? ?? [];
                            if (friendsRaw.isEmpty)
                              return const Center(
                                child: Text('No friends yet'),
                              );
                            final friends =
                                friendsRaw
                                    .map<Map<String, dynamic>>(
                                      (f) =>
                                          f is Map
                                              ? Map<String, dynamic>.from(f)
                                              : <String, dynamic>{
                                                'id': f.toString(),
                                              },
                                    )
                                    .toList();
                            return ListView.separated(
                              itemCount: friends.length,
                              separatorBuilder:
                                  (_, __) => const Divider(height: 1),
                              itemBuilder: (ctx2, i) {
                                final f = friends[i];
                                return _friendTile(f);
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 380,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Requests',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: StreamBuilder<
                                QuerySnapshot<Map<String, dynamic>>?
                              >(
                                stream: reqStream,
                                builder: (ctx, snap) {
                                  if (!snap.hasData)
                                    return const Center(
                                      child: CircularProgressIndicator(),
                                    );
                                  final docs = snap.data!.docs;
                                  if (docs.isEmpty)
                                    return const Center(
                                      child: Text('No incoming requests'),
                                    );
                                  return ListView.separated(
                                    itemCount: docs.length,
                                    separatorBuilder:
                                        (_, __) => const Divider(height: 1),
                                    itemBuilder: (ctx2, i) {
                                      final doc = docs[i];
                                      final data = doc.data();
                                      final fromName =
                                          data['fromName'] ??
                                          data['fromEmail'] ??
                                          'Someone';
                                      final fromEmail = data['fromEmail'] ?? '';
                                      return ListTile(
                                        title: Text(fromName),
                                        subtitle: Text(fromEmail),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              icon: const Icon(
                                                Icons.check,
                                                color: Colors.green,
                                              ),
                                              onPressed:
                                                  () => _acceptRequest(
                                                    doc.id,
                                                    data,
                                                  ),
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.close,
                                                color: Colors.red,
                                              ),
                                              onPressed:
                                                  () => _declineRequest(doc.id),
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
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
