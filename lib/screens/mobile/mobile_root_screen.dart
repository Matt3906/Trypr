import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:trypr/screens/sign_in_screen.dart';
import 'package:trypr/screens/trip_builder_screen.dart';
import 'package:trypr/screens/trip_detail_screen.dart';
import 'package:trypr/screens/trip_planning_screen.dart';
import 'package:trypr/services/name_lookup.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/widgets/map_embed.dart';

class MobileRootScreen extends StatefulWidget {
  const MobileRootScreen({super.key});

  @override
  State<MobileRootScreen> createState() => _MobileRootScreenState();
}

class _MobileRootScreenState extends State<MobileRootScreen> {
  int _mode = 0;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        final user = snap.data;
        if (user == null) return const _MobileSignedOutView();

        return Scaffold(
          backgroundColor: const Color(0xFFF5F6F8),
          appBar: AppBar(
            title: const Text('Trypr'),
            actions: [
              IconButton(
                tooltip: 'Account',
                onPressed: () => Navigator.of(context).pushNamed('/account'),
                icon: const Icon(Icons.account_circle_outlined),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: CupertinoSlidingSegmentedControl<int>(
                    groupValue: _mode,
                    children: const {
                      0: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        child: Text('Planning'),
                      ),
                      1: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        child: Text('Active Trip'),
                      ),
                    },
                    onValueChanged: (v) {
                      if (v == null) return;
                      setState(() => _mode = v);
                    },
                  ),
                ),
                Expanded(
                  child:
                      _mode == 0
                          ? _PlanningModeView(user: user)
                          : _ActiveTripModeView(user: user),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MobileSignedOutView extends StatelessWidget {
  const _MobileSignedOutView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.travel_explore, size: 42),
                    const SizedBox(height: 12),
                    Text(
                      'Trip Archive',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Sign in to open your planning workspace and active trip mode with shared chat, maps, expenses, itinerary, and photos.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SignInScreen(),
                          ),
                        );
                      },
                      child: const Text('Sign in'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlanningModeView extends StatelessWidget {
  final User user;
  const _PlanningModeView({required this.user});

  Stream<QuerySnapshot<Map<String, dynamic>>> _trips() {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('trips')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Future<void> _openPlanner(
    BuildContext context,
    String localDocId,
    Map<String, dynamic> localData,
  ) async {
    final tripRefPath = _tripRefPathForLocalDoc(
      currentUid: user.uid,
      localDocId: localDocId,
      localData: localData,
    );
    final resolved = await _resolveTripDataForPath(
      localData: localData,
      tripRefPath: tripRefPath,
    );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => TripPlanningScreen(
              tripId: _tripIdFromTripPath(tripRefPath),
              tripRefPath: tripRefPath,
              tripData: resolved,
            ),
      ),
    );
  }

  Future<void> _openDetails(
    BuildContext context,
    String localDocId,
    Map<String, dynamic> localData,
  ) async {
    final tripRefPath = _tripRefPathForLocalDoc(
      currentUid: user.uid,
      localDocId: localDocId,
      localData: localData,
    );
    final resolved = await _resolveTripDataForPath(
      localData: localData,
      tripRefPath: tripRefPath,
    );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TripDetailScreen(docId: localDocId, data: resolved),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Card(
            elevation: 0,
            color: const Color(0xFFEEF4FF),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Planning Mode: route building, docs, notes, and itinerary.',
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const TripBuilderScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Create Trip'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _trips(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const Center(
                  child: Text('No trips yet. Create one to begin planning.'),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: docs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  final data = doc.data();
                  final displayName = _tripName(data);
                  final stopCount = _waypointsFromTrip(data).length;
                  final dateRange = _tripDateRange(data);
                  return Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '$dateRange • $stopCount stops',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed:
                                      () => _openDetails(
                                        context,
                                        doc.id,
                                        Map<String, dynamic>.from(data),
                                      ),
                                  icon: const Icon(Icons.map_outlined),
                                  label: const Text('Details'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed:
                                      () => _openPlanner(
                                        context,
                                        doc.id,
                                        Map<String, dynamic>.from(data),
                                      ),
                                  icon: const Icon(Icons.edit_calendar_rounded),
                                  label: const Text('Plan'),
                                ),
                              ),
                            ],
                          ),
                        ],
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
}

class _ActiveTripModeView extends StatefulWidget {
  final User user;
  const _ActiveTripModeView({required this.user});

  @override
  State<_ActiveTripModeView> createState() => _ActiveTripModeViewState();
}

class _ActiveTripModeViewState extends State<_ActiveTripModeView> {
  _SelectedTrip? _selectedTrip;
  bool _resolving = false;

  Stream<QuerySnapshot<Map<String, dynamic>>> _trips() {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(widget.user.uid)
        .collection('trips')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Future<void> _selectTrip(
    String localDocId,
    Map<String, dynamic> local,
  ) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final tripRefPath = _tripRefPathForLocalDoc(
        currentUid: widget.user.uid,
        localDocId: localDocId,
        localData: local,
      );
      final resolved = await _resolveTripDataForPath(
        localData: local,
        tripRefPath: tripRefPath,
      );
      if (!mounted) return;
      setState(() {
        _selectedTrip = _SelectedTrip(
          localDocId: localDocId,
          tripRefPath: tripRefPath,
          tripData: resolved,
        );
      });
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedTrip;
    if (selected != null) {
      return _ActiveTripWorkspace(
        me: widget.user,
        selectedTrip: selected,
        onChangeTrip: () => setState(() => _selectedTrip = null),
      );
    }

    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Card(
            elevation: 0,
            color: Color(0xFFF0FFF4),
            child: Padding(
              padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Text(
                'Active Trip Mode: one place for live chat, costs, itinerary, map, and shared photos.',
              ),
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _trips(),
            builder: (context, snap) {
              if (!snap.hasData || _resolving) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const Center(
                  child: Text('No trips available yet for active mode.'),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: docs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  final data = doc.data();
                  final name = _tripName(data);
                  final stopCount = _waypointsFromTrip(data).length;
                  return Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: Color(0xFFE6ECFF),
                        child: Icon(Icons.flag_outlined),
                      ),
                      title: Text(name),
                      subtitle: Text(
                        '${_tripDateRange(data)} • $stopCount stops',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap:
                          () => _selectTrip(
                            doc.id,
                            Map<String, dynamic>.from(data),
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
}

class _SelectedTrip {
  final String localDocId;
  final String tripRefPath;
  final Map<String, dynamic> tripData;

  const _SelectedTrip({
    required this.localDocId,
    required this.tripRefPath,
    required this.tripData,
  });
}

class _ActiveTripWorkspace extends StatefulWidget {
  final User me;
  final _SelectedTrip selectedTrip;
  final VoidCallback onChangeTrip;

  const _ActiveTripWorkspace({
    required this.me,
    required this.selectedTrip,
    required this.onChangeTrip,
  });

  @override
  State<_ActiveTripWorkspace> createState() => _ActiveTripWorkspaceState();
}

class _ActiveTripWorkspaceState extends State<_ActiveTripWorkspace> {
  late final DocumentReference<Map<String, dynamic>> _tripRef;
  late Map<String, dynamic> _tripData;
  final _chatCtl = TextEditingController();
  final _expenseTitleCtl = TextEditingController();
  final _expenseAmountCtl = TextEditingController();
  final _nameCache = <String, String>{};
  final _picker = ImagePicker();
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _tripSub;
  bool _sendingChat = false;
  bool _addingExpense = false;
  bool _uploadingPhoto = false;

  List<String> _participants = const [];

  @override
  void initState() {
    super.initState();
    _tripRef = FirebaseFirestore.instance.doc(widget.selectedTrip.tripRefPath);
    _tripData = Map<String, dynamic>.from(widget.selectedTrip.tripData);
    _participants = _participantsFromTrip(_tripData, widget.me.uid);
    _primeNameCache();
    _tripSub = _tripRef.snapshots().listen((snap) {
      if (!snap.exists) return;
      final remote = snap.data() ?? <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _tripData = Map<String, dynamic>.from(_tripData)..addAll(remote);
        _participants = _participantsFromTrip(_tripData, widget.me.uid);
      });
      _primeNameCache();
    });
  }

  Future<void> _primeNameCache() async {
    await ensureNameCache(
      _nameCache,
      _participants,
      currentUidForFriendsFallback: widget.me.uid,
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tripSub?.cancel();
    _chatCtl.dispose();
    _expenseTitleCtl.dispose();
    _expenseAmountCtl.dispose();
    super.dispose();
  }

  Future<void> _sendChatMessage() async {
    if (_sendingChat) return;
    final text = _chatCtl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sendingChat = true);
    try {
      await _tripRef.collection('messages').add({
        'senderUid': widget.me.uid,
        'senderName':
            widget.me.displayName?.trim().isNotEmpty == true
                ? widget.me.displayName!.trim()
                : (widget.me.email?.split('@').first ?? 'Traveler'),
        'text': text,
        'createdAt': Timestamp.now(),
      });
      _chatCtl.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(SnackBar(content: Text('Failed to send: $e')));
    } finally {
      if (mounted) setState(() => _sendingChat = false);
    }
  }

  Future<void> _addExpense() async {
    if (_addingExpense) return;
    final title = _expenseTitleCtl.text.trim();
    final amount = double.tryParse(_expenseAmountCtl.text.trim());
    if (title.isEmpty || amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Enter a title and amount > 0')),
      );
      return;
    }
    setState(() => _addingExpense = true);
    try {
      await _tripRef.collection('expenses').add({
        'title': title,
        'amount': amount,
        'splitMode': 'group',
        'category': 'Other',
        'paidByUid': widget.me.uid,
        'createdAt': Timestamp.now(),
        'createdByUid': widget.me.uid,
      });
      _expenseTitleCtl.clear();
      _expenseAmountCtl.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(SnackBar(content: Text('Failed to add expense: $e')));
    } finally {
      if (mounted) setState(() => _addingExpense = false);
    }
  }

  Future<void> _uploadPhoto() async {
    if (_uploadingPhoto) return;
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 84,
      maxWidth: 2200,
    );
    if (picked == null) return;

    setState(() => _uploadingPhoto = true);
    try {
      final bytes = await picked.readAsBytes();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final tripId = _tripIdFromTripPath(widget.selectedTrip.tripRefPath);
      final ext = _fileExt(picked.name);
      final storagePath = 'tripPhotos/$tripId/${ts}_${widget.me.uid}.$ext';
      final ref = FirebaseStorage.instance.ref(storagePath);
      final meta = SettableMetadata(
        contentType: _contentTypeForExt(ext),
        customMetadata: {
          'tripRef': widget.selectedTrip.tripRefPath,
          'uploadedByUid': widget.me.uid,
        },
      );
      final task = await ref.putData(bytes, meta);
      final url = await task.ref.getDownloadURL();

      final photoEntry = {
        'url': url,
        'storagePath': storagePath,
        'uploadedByUid': widget.me.uid,
        'uploadedAt': Timestamp.now(),
        'fileName': picked.name,
      };
      await _tripRef.update({
        'tripPhotos': FieldValue.arrayUnion([photoEntry]),
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showTryprSnackBar(SnackBar(content: Text('Photo upload failed: $e')));
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tripName = _tripName(_tripData);
    final waypoints = _waypointsFromTrip(_tripData);
    return DefaultTabController(
      length: 5,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tripName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _tripDateRange(_tripData),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: widget.onChangeTrip,
                      icon: const Icon(Icons.swap_horiz_rounded),
                      label: const Text('Change'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: TabBar(
              isScrollable: true,
              tabs: [
                Tab(text: 'Chat'),
                Tab(text: 'Expenses'),
                Tab(text: 'Itinerary'),
                Tab(text: 'Map'),
                Tab(text: 'Photos'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildChatTab(),
                _buildExpensesTab(),
                _buildItineraryTab(),
                _buildMapTab(waypoints),
                _buildPhotosTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatTab() {
    return Column(
      children: [
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream:
                _tripRef
                    .collection('messages')
                    .orderBy('createdAt', descending: true)
                    .snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const Center(child: Text('No messages yet'));
              }
              return ListView.builder(
                reverse: true,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final data = docs[index].data();
                  final senderUid = (data['senderUid'] ?? '').toString();
                  final isMe = senderUid == widget.me.uid;
                  final fallbackName = (data['senderName'] ?? '').toString();
                  final senderName =
                      isMe
                          ? 'You'
                          : (_nameCache[senderUid] ??
                              (fallbackName.isNotEmpty
                                  ? fallbackName
                                  : senderUid));
                  final text = (data['text'] ?? '').toString();
                  final dt = _dateFromAny(data['createdAt']);
                  final time =
                      dt == null ? '' : DateFormat('h:mm a').format(dt);
                  return Align(
                    alignment:
                        isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      constraints: const BoxConstraints(maxWidth: 320),
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                      decoration: BoxDecoration(
                        color:
                            isMe
                                ? const Color(0xFFDFEEFF)
                                : const Color(0xFFF1F3F5),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            senderName,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(text),
                          if (time.isNotEmpty) ...[
                            const SizedBox(height: 5),
                            Text(
                              time,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatCtl,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: 'Message the group…',
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _sendingChat ? null : _sendChatMessage,
                child:
                    _sendingChat
                        ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildExpensesTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  TextField(
                    controller: _expenseTitleCtl,
                    decoration: const InputDecoration(
                      labelText: 'Expense title',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _expenseAmountCtl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Amount',
                            prefixText: '\$',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _addingExpense ? null : _addExpense,
                        icon: const Icon(Icons.add),
                        label:
                            _addingExpense
                                ? const Text('Adding…')
                                : const Text('Add'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream:
                _tripRef
                    .collection('expenses')
                    .orderBy('createdAt', descending: true)
                    .snapshots(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const Center(child: Text('No expenses yet'));
              }
              var total = 0.0;
              for (final d in docs) {
                total += ((d.data()['amount'] as num?)?.toDouble() ?? 0.0);
              }
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Total tracked: \$${total.toStringAsFixed(2)}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      itemCount: docs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final data = docs[index].data();
                        final title = (data['title'] ?? 'Expense').toString();
                        final amount =
                            ((data['amount'] as num?)?.toDouble() ?? 0.0);
                        final paidByUid = (data['paidByUid'] ?? '').toString();
                        final paidByName =
                            _nameCache[paidByUid] ??
                            (paidByUid.isNotEmpty ? paidByUid : 'Unassigned');
                        return Card(
                          elevation: 0,
                          child: ListTile(
                            title: Text(title),
                            subtitle: Text('Paid by $paidByName'),
                            trailing: Text(
                              '\$${amount.toStringAsFixed(2)}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildItineraryTab() {
    final days = _itineraryFromTrip(_tripData);
    if (days.isEmpty) {
      return const Center(child: Text('No itinerary yet'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      itemCount: days.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final day = days[index];
        final title =
            (day['title'] ?? day['name'] ?? 'Day ${index + 1}').toString();
        final notes = (day['notes'] ?? '').toString();
        final activitiesRaw = day['activities'];
        final activities =
            (activitiesRaw is List)
                ? activitiesRaw.whereType<Map>().toList(growable: false)
                : const <Map>[];
        return Card(
          elevation: 0,
          child: ExpansionTile(
            title: Text(title),
            subtitle:
                notes.isEmpty
                    ? null
                    : Text(notes, maxLines: 1, overflow: TextOverflow.ellipsis),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            children:
                activities.isEmpty
                    ? [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('No activities yet'),
                      ),
                    ]
                    : activities
                        .map((item) {
                          final map = Map<String, dynamic>.from(
                            item.cast<String, dynamic>(),
                          );
                          final activityTitle =
                              (map['title'] ??
                                      map['name'] ??
                                      map['activity'] ??
                                      'Activity')
                                  .toString();
                          final time =
                              (map['time'] ?? map['startTime'] ?? '')
                                  .toString();
                          final category = (map['category'] ?? '').toString();
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(top: 3),
                                  child: Icon(Icons.circle, size: 10),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(activityTitle),
                                      if (time.isNotEmpty ||
                                          category.isNotEmpty)
                                        Text(
                                          [time, category]
                                              .where((v) => v.isNotEmpty)
                                              .join(' • '),
                                          style:
                                              Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        })
                        .toList(growable: false),
          ),
        );
      },
    );
  }

  Widget _buildMapTab(List<Map<String, dynamic>> waypoints) {
    if (waypoints.isEmpty) {
      return const Center(child: Text('No route points available'));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: MapEmbed(points: waypoints),
      ),
    );
  }

  Widget _buildPhotosTab() {
    final photos = _tripPhotosFromTrip(_tripData);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Row(
            children: [
              Text(
                'Shared photos (${photos.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _uploadingPhoto ? null : _uploadPhoto,
                icon: const Icon(Icons.upload_rounded),
                label:
                    _uploadingPhoto
                        ? const Text('Uploading…')
                        : const Text('Upload'),
              ),
            ],
          ),
        ),
        Expanded(
          child:
              photos.isEmpty
                  ? const Center(
                    child: Text('No photos yet. Upload one to start sharing.'),
                  )
                  : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 0.84,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: photos.length,
                    itemBuilder: (context, index) {
                      final photo = photos[index];
                      final url = (photo['url'] ?? '').toString();
                      final uploaderUid =
                          (photo['uploadedByUid'] ?? '').toString();
                      final uploader =
                          _nameCache[uploaderUid] ??
                          (uploaderUid.isNotEmpty ? uploaderUid : 'Traveler');
                      final uploaded = _dateFromAny(photo['uploadedAt']);
                      final uploadedLabel =
                          uploaded == null
                              ? ''
                              : DateFormat('MMM d').format(uploaded);
                      if (url.isEmpty) return const SizedBox.shrink();
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.network(url, fit: BoxFit.cover),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: Container(
                                color: Colors.black54,
                                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                                child: Text(
                                  uploadedLabel.isEmpty
                                      ? uploader
                                      : '$uploader • $uploadedLabel',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }
}

String? _tripRefPathFromAny(dynamic raw) {
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (raw is DocumentReference) return raw.path;
  final text = raw?.toString().trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

String _tripRefPathForLocalDoc({
  required String currentUid,
  required String localDocId,
  required Map<String, dynamic> localData,
}) {
  return _tripRefPathFromAny(localData['tripRef']) ??
      'users/$currentUid/trips/$localDocId';
}

String _tripIdFromTripPath(String tripPath) {
  final segs = tripPath.split('/');
  if (segs.length >= 4 && segs[0] == 'users' && segs[2] == 'trips') {
    return segs[3];
  }
  return segs.isNotEmpty ? segs.last : tripPath;
}

bool _hasWaypoints(Map<String, dynamic> data) {
  final w = data['waypoints'];
  return w is List && w.isNotEmpty;
}

Future<Map<String, dynamic>> _resolveTripDataForPath({
  required Map<String, dynamic> localData,
  required String tripRefPath,
}) async {
  final out = Map<String, dynamic>.from(localData);
  out['tripRef'] = tripRefPath;

  if (_hasWaypoints(out)) return out;

  try {
    final remoteDoc = await FirebaseFirestore.instance.doc(tripRefPath).get();
    if (!remoteDoc.exists) return out;

    final remote = remoteDoc.data() ?? <String, dynamic>{};
    final merged = Map<String, dynamic>.from(remote)..addAll(out);
    final remoteWaypoints = remote['waypoints'] ?? remote['stops'];
    if (remoteWaypoints is List && remoteWaypoints.isNotEmpty) {
      merged['waypoints'] = remoteWaypoints;
    }
    merged['tripRef'] = tripRefPath;
    return merged;
  } catch (_) {
    return out;
  }
}

String _tripName(Map<String, dynamic> data) {
  final name =
      (data['name'] ?? data['tripName'] ?? data['title'] ?? '')
          .toString()
          .trim();
  return name.isEmpty ? 'Untitled Trip' : name;
}

String _tripDateRange(Map<String, dynamic> data) {
  final start = _dateFromAny(data['startDate']);
  final end = _dateFromAny(data['endDate']);
  if (start != null && end != null) {
    return '${DateFormat('MMM d').format(start)} – ${DateFormat('MMM d').format(end)}';
  }
  if (start != null) return DateFormat('MMM d').format(start);
  if (end != null) return DateFormat('MMM d').format(end);
  return 'Dates TBD';
}

DateTime? _dateFromAny(dynamic raw) {
  if (raw is Timestamp) return raw.toDate();
  if (raw is DateTime) return raw;
  if (raw is String && raw.trim().isNotEmpty) {
    return DateTime.tryParse(raw.trim());
  }
  return null;
}

List<Map<String, dynamic>> _waypointsFromTrip(Map<String, dynamic> data) {
  final raw = data['waypoints'] ?? data['stops'];
  if (raw is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final m = Map<String, dynamic>.from(entry.cast<String, dynamic>());
    final lat = m['lat'] ?? m['latitude'];
    final lon = m['lon'] ?? m['lng'] ?? m['longitude'];
    out.add({
      'lat': lat,
      'lon': lon,
      'name': (m['name'] ?? m['title'] ?? m['placeName'] ?? '').toString(),
    });
  }
  return out;
}

List<Map<String, dynamic>> _itineraryFromTrip(Map<String, dynamic> data) {
  final raw = data['tripItineraryDays'] ?? data['itineraryDays'];
  if (raw is List && raw.isNotEmpty) {
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e.cast<String, dynamic>()))
        .toList();
  }

  final points = _waypointsFromTrip(data);
  if (points.isEmpty) return const [];
  return [
    for (int i = 0; i < points.length; i++)
      {
        'title': 'Day ${i + 1}',
        'activities': [
          {
            'title':
                points[i]['name']?.toString().trim().isNotEmpty == true
                    ? points[i]['name']
                    : 'Stop ${i + 1}',
          },
        ],
      },
  ];
}

List<String> _participantsFromTrip(Map<String, dynamic> data, String meUid) {
  final out = <String>{meUid};
  final path = _tripRefPathFromAny(data['tripRef']) ?? '';
  final segs = path.split('/');
  if (segs.length >= 2 && segs[0] == 'users') {
    out.add(segs[1]);
  }
  final shared = data['sharedWith'];
  if (shared is List) {
    for (final s in shared) {
      final uid = s.toString().trim();
      if (uid.isNotEmpty) out.add(uid);
    }
  }
  return out.toList(growable: false);
}

List<Map<String, dynamic>> _tripPhotosFromTrip(Map<String, dynamic> data) {
  final raw = data['tripPhotos'];
  if (raw is! List) return const [];
  final out =
      raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e.cast<String, dynamic>()))
          .where((m) => (m['url'] ?? '').toString().trim().isNotEmpty)
          .toList();
  out.sort((a, b) {
    final ad = _dateFromAny(a['uploadedAt']);
    final bd = _dateFromAny(b['uploadedAt']);
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return bd.compareTo(ad);
  });
  return out;
}

String _fileExt(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'png';
  if (lower.endsWith('.webp')) return 'webp';
  if (lower.endsWith('.heic')) return 'heic';
  return 'jpg';
}

String _contentTypeForExt(String ext) {
  switch (ext.toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'heic':
      return 'image/heic';
    default:
      return 'image/jpeg';
  }
}
