import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/screens/verified_trip_builder_screen.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;

class VerifiedTripsScreen extends StatefulWidget {
  const VerifiedTripsScreen({super.key});

  @override
  State<VerifiedTripsScreen> createState() => _VerifiedTripsScreenState();
}

class _VerifiedTripsScreenState extends State<VerifiedTripsScreen> {
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _adminDoc;
  StreamSubscription<User?>? _authSub;

  Widget _imageFromSource(String src, {required double width, required double height}) {
    final s = src.trim();
    if (s.isEmpty) return const SizedBox.shrink();
    if (s.startsWith('data:image')) {
      if (kIsWeb) {
        return Image.network(
          s,
          width: width,
          height: height,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      }
      try {
        final bytes = base64Decode(s.split(',').last);
        return Image.memory(
          bytes,
          width: width,
          height: height,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      } catch (_) {
        return const SizedBox.shrink();
      }
    }
    if (s.startsWith('http')) {
      return Image.network(
        s,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return Image.asset(
      s,
      width: width,
      height: height,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  @override
  void initState() {
    super.initState();
    void syncAdminDoc(User? u) {
      setState(() {
        _adminDoc =
            u == null
                ? null
                : FirebaseFirestore.instance
                    .collection('admins')
                    .doc(u.uid)
                    .snapshots();
      });
    }

    syncAdminDoc(FirebaseAuth.instance.currentUser);
    _authSub = FirebaseAuth.instance.authStateChanges().listen(syncAdminDoc);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Widget _errorBox(String title, Object? error) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(
                (error ?? '').toString(),
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.black54),
              ),
              const SizedBox(height: 10),
              const Text(
                'If this mentions permissions, make sure your Firestore rules are deployed and that your admin document ID exactly matches your Firebase Auth UID.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openCreateBuilder() async {
    await Navigator.of(context).push(VerifiedTripBuilderScreen.route());
  }

  @override
  Widget build(BuildContext context) {
    final trips =
        FirebaseFirestore.instance
            .collection('verifiedTrips')
            .orderBy('createdAt', descending: true)
            .snapshots();

    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      floatingActionButton: StreamBuilder<
        DocumentSnapshot<Map<String, dynamic>>
      >(
        stream: _adminDoc,
        builder: (ctx, snap) {
          if (snap.hasError) {
            // If admin doc read fails (permissions/rules), don't block page.
            return const SizedBox.shrink();
          }
          final isAdmin = (snap.data?.exists ?? false);
          if (!isAdmin) return const SizedBox.shrink();
          return FloatingActionButton(
            onPressed: _openCreateBuilder,
            child: const Icon(Icons.add),
          );
        },
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: trips,
        builder: (ctx, snap) {
          if (snap.hasError) {
            return _errorBox('Failed to load verified trips', snap.error);
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('No verified trips yet'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (ctx2, i) {
              final data = docs[i].data();
              final title = (data['title'] ?? '').toString();
              final subtitle = (data['subtitle'] ?? '').toString();
              final desc = (data['description'] ?? '').toString();
              final cover = (data['coverImage'] ?? '').toString();
              final days = data['recommendedDays'] ?? data['days'];

              Widget? leading;
              if (cover.isNotEmpty) {
                leading = ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _imageFromSource(cover, width: 86, height: 64),
                );
              }

              return Card(
                child: ListTile(
                  leading: leading,
                  title: Text(title),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (subtitle.isNotEmpty) Text(subtitle),
                      if (days is int) Text('Recommended: $days days'),
                    ],
                  ),
                  onTap: () {
                    showDialog<void>(
                      context: context,
                      builder:
                          (_) => AlertDialog(
                            title: Text(title),
                            content: Text(desc),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
