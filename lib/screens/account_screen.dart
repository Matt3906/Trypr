import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:trypr/widgets/top_taskbar.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:math' as math;
// Web-only file picker
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

class AccountScreen extends StatefulWidget {
  const AccountScreen({Key? key}) : super(key: key);

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  User? get _user => FirebaseAuth.instance.currentUser;

  Stream<DocumentSnapshot<Map<String, dynamic>>>? _userDocStream() {
    final u = _user;
    if (u == null) return null;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(u.uid)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    final stream = _userDocStream();

    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child:
                    stream == null
                        ? _signedOutContent(context)
                        : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                          stream: stream,
                          builder: (ctx, snap) {
                            if (snap.connectionState == ConnectionState.waiting)
                              return const SizedBox(
                                height: 180,
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            final doc = snap.data;
                            final data = doc?.data() ?? <String, dynamic>{};

                            final displayName =
                                data['name'] ??
                                data['displayName'] ??
                                _user?.displayName ??
                                '—';
                            final email = _user?.email ?? data['email'] ?? '—';
                            final subscription =
                                data['subscriptionType'] ??
                                data['subscription'] ??
                                'Free';
                            final city = data['city'] ?? '—';
                            String dobStr = '—';
                            if (data['dob'] != null) {
                              try {
                                final d = data['dob'];
                                DateTime dt;
                                if (d is String)
                                  dt = DateTime.parse(d);
                                else if (d is Timestamp)
                                  dt = d.toDate();
                                else
                                  dt = DateTime.parse(d.toString());
                                dobStr =
                                    '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
                              } catch (_) {}
                            }
                            final sex =
                                (data['sex'] ?? data['gender'] ?? '—')
                                    .toString();
                            final profileImage =
                                data['profileImageDataUrl'] as String?;

                            final friendsRaw =
                                data['friends'] as List<dynamic>?;
                            final friends = <Map<String, dynamic>>[];
                            if (friendsRaw != null) {
                              for (final f in friendsRaw) {
                                if (f is Map) {
                                  friends.add(Map<String, dynamic>.from(f));
                                } else if (f is String) {
                                  friends.add({'id': f});
                                }
                              }
                            }

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'Account',
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 16),
                                // Profile header row with avatar
                                Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 36,
                                      backgroundColor: Colors.grey.shade200,
                                      backgroundImage:
                                          profileImage != null
                                              ? (kIsWeb
                                                  ? NetworkImage(profileImage)
                                                  : MemoryImage(
                                                        base64Decode(
                                                          profileImage
                                                              .split(',')
                                                              .last,
                                                        ),
                                                      )
                                                      as ImageProvider)
                                              : null,
                                      child:
                                          profileImage == null
                                              ? const Icon(
                                                Icons.person,
                                                size: 36,
                                                color: Colors.grey,
                                              )
                                              : null,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: _infoRow('Name', displayName),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                _infoRow('Email', email),
                                const SizedBox(height: 8),
                                _infoRow('City', city.toString()),
                                const SizedBox(height: 8),
                                _infoRow('Date of birth', dobStr),
                                const SizedBox(height: 8),
                                _infoRow('Sex', sex.toString()),
                                const SizedBox(height: 8),
                                _infoRow(
                                  'Subscription',
                                  subscription.toString(),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Friends',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 8),
                                if (friends.isEmpty)
                                  const Text(
                                    'No friends added yet',
                                    style: TextStyle(color: Colors.black54),
                                  )
                                else ...[
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children:
                                        friends.map((f) {
                                          final fname =
                                              (f['name'] ??
                                                      f['displayName'] ??
                                                      f['email'] ??
                                                      f['id'] ??
                                                      'Friend')
                                                  .toString();
                                          return Chip(label: Text(fname));
                                        }).toList(),
                                  ),
                                ],
                                const SizedBox(height: 18),
                                Row(
                                  children: [
                                    ElevatedButton.icon(
                                      onPressed: () {
                                        _showEditProfile(context, data);
                                      },
                                      icon: const Icon(Icons.edit),
                                      label: const Text('Edit profile'),
                                    ),
                                    const SizedBox(width: 12),
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        await FirebaseAuth.instance.signOut();
                                        if (mounted)
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text('Signed out'),
                                            ),
                                          );
                                      },
                                      icon: const Icon(Icons.logout),
                                      label: const Text('Sign out'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                // Debug: show raw user document for troubleshooting
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    onPressed: () {
                                      showDialog<void>(
                                        context: context,
                                        builder:
                                            (ctx) => AlertDialog(
                                              title: const Text(
                                                'Raw user document',
                                              ),
                                              content: SingleChildScrollView(
                                                child: SelectableText(
                                                  JsonEncoder.withIndent(
                                                    '  ',
                                                  ).convert(data),
                                                ),
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed:
                                                      () =>
                                                          Navigator.of(
                                                            ctx,
                                                          ).pop(),
                                                  child: const Text('Close'),
                                                ),
                                              ],
                                            ),
                                      );
                                    },
                                    icon: const Icon(Icons.bug_report_outlined),
                                    label: const Text('Show raw doc'),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _signedOutContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Account',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        const Text(
          'Sign in to view your account details',
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pushNamed('/sign-in'),
          child: const Text('Sign in'),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 140,
          child: Text(label, style: const TextStyle(color: Colors.black54)),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  // Show bottom sheet to edit profile fields: name, city, dob, sex, visited countries
  Future<void> _showEditProfile(
    BuildContext context,
    Map<String, dynamic> data,
  ) async {
    final uid = _user?.uid;
    if (uid == null) return;
    // Use a dedicated StatefulWidget for the bottom sheet so we can safely
    // check `mounted` inside async callbacks and avoid calling setState
    // after the sheet has been disposed.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder:
          (ctx) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: _EditProfileSheet(
              uid: uid,
              data: Map<String, dynamic>.from(data),
            ),
          ),
    );
  }
}

class _EditProfileSheet extends StatefulWidget {
  final String uid;
  final Map<String, dynamic> data;

  const _EditProfileSheet({Key? key, required this.uid, required this.data})
    : super(key: key);

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late TextEditingController nameCtl;
  late TextEditingController cityCtl;
  DateTime? dob;
  String sex = 'male';
  final Set<String> visited = {};
  String? localProfileImage;
  bool removeImage = false;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final data = widget.data;
    nameCtl = TextEditingController(
      text: (data['name'] ?? data['displayName'] ?? '').toString(),
    );
    cityCtl = TextEditingController(text: (data['city'] ?? '').toString());
    if (data['dob'] is String) {
      try {
        dob = DateTime.parse(data['dob']);
      } catch (_) {}
    } else if (data['dob'] is Timestamp) {
      dob = (data['dob'] as Timestamp).toDate();
    }
    final s = (data['sex'] ?? data['gender'] ?? '').toString().toLowerCase();
    if (s == 'female') sex = 'female';
    final vc = data['visitedCountries'] as List<dynamic>?;
    if (vc != null) visited.addAll(vc.map((e) => e.toString()));
    localProfileImage = data['profileImageDataUrl'] as String?;
  }

  @override
  void dispose() {
    nameCtl.dispose();
    cityCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Edit profile',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: cityCtl,
                  decoration: const InputDecoration(labelText: 'City'),
                ),
                const SizedBox(height: 8),
                const SizedBox(height: 8),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 36,
                      backgroundColor: Colors.grey.shade200,
                      backgroundImage:
                          localProfileImage != null
                              ? (kIsWeb
                                  ? NetworkImage(localProfileImage!)
                                  : MemoryImage(
                                        base64Decode(
                                          localProfileImage!.split(',').last,
                                        ),
                                      )
                                      as ImageProvider)
                              : null,
                      child:
                          localProfileImage == null
                              ? const Icon(
                                Icons.person,
                                size: 36,
                                color: Colors.grey,
                              )
                              : null,
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _onUploadPressed,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Upload profile picture'),
                    ),
                    const SizedBox(width: 12),
                    if (localProfileImage != null)
                      TextButton(
                        onPressed: () {
                          setState(() {
                            localProfileImage = null;
                            removeImage = true;
                          });
                        },
                        child: const Text('Remove'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: InputDecorator(
                        decoration: const InputDecoration(labelText: 'Sex'),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: sex,
                            items: const [
                              DropdownMenuItem(
                                value: 'male',
                                child: Text('Male'),
                              ),
                              DropdownMenuItem(
                                value: 'female',
                                child: Text('Female'),
                              ),
                            ],
                            onChanged: (v) => setState(() => sex = v ?? 'male'),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Date of birth',
                        ),
                        child: InkWell(
                          onTap: () async {
                            final now = DateTime.now();
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: dob ?? DateTime(now.year - 25),
                              firstDate: DateTime(1900),
                              lastDate: DateTime(now.year),
                            );
                            if (picked != null && mounted)
                              setState(() => dob = picked);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12.0),
                            child: Text(
                              dob != null
                                  ? '${dob!.year}-${dob!.month.toString().padLeft(2, '0')}-${dob!.day.toString().padLeft(2, '0')}'
                                  : 'Select date',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Visited countries',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    TextButton(
                      onPressed: () async {
                        final newVisited = await _showCountryPicker(
                          context,
                          visited,
                        );
                        if (newVisited != null && mounted)
                          setState(() {
                            visited.clear();
                            visited.addAll(newVisited);
                          });
                      },
                      child: const Text('Edit'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: visited.map((c) => Chip(label: Text(c))).toList(),
                ),
                const SizedBox(height: 16),
                const SizedBox(height: 8),
                Text(
                  'Visited map',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 160,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Colors.grey.shade50,
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children:
                          visited
                              .map(
                                (c) => Chip(
                                  backgroundColor: Colors.blue.shade50,
                                  label: Text(c),
                                ),
                              )
                              .toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _onSavePressed,
                        child: const Text('Save'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
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
  }

  Future<void> _onUploadPressed() async {
    if (!kIsWeb) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile upload currently supported on web only'),
          ),
        );
      return;
    }
    final input = html.FileUploadInputElement();
    input.accept = 'image/*';
    input.click();
    input.onChange.listen((e) {
      final files = input.files;
      if (files == null || files.isEmpty) return;
      final reader = html.FileReader();
      reader.readAsDataUrl(files[0]);
      reader.onLoad.first.then((_) async {
        final result = reader.result as String?;
        if (result != null) {
          try {
            final img = html.ImageElement();
            img.src = result;
            await img.onLoad.first;
            final w = img.width ?? 0;
            final h = img.height ?? 0;
            final srcSize = (w < h ? w : h);
            const int targetSize = 256;
            final canvas = html.CanvasElement(
              width: targetSize,
              height: targetSize,
            );
            final ctxCanvas = canvas.context2D;
            ctxCanvas.beginPath();
            ctxCanvas.arc(
              targetSize / 2,
              targetSize / 2,
              targetSize / 2,
              0,
              2 * math.pi,
            );
            ctxCanvas.clip();
            final sx = ((w - srcSize) / 2).toInt();
            final sy = ((h - srcSize) / 2).toInt();
            ctxCanvas.drawImageScaledFromSource(
              img,
              sx,
              sy,
              srcSize,
              srcSize,
              0,
              0,
              targetSize,
              targetSize,
            );
            final cropped = canvas.toDataUrl('image/png');
            if (!mounted) return;
            setState(() {
              localProfileImage = cropped;
              removeImage = false;
            });
          } catch (_) {
            if (!mounted) return;
            setState(() {
              localProfileImage = result;
              removeImage = false;
            });
          }
        }
      });
    });
  }

  Future<void> _onSavePressed() async {
    if (!_formKey.currentState!.validate()) return;
    final docRef = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.uid);
    final upd = <String, dynamic>{
      'name': nameCtl.text.trim(),
      'displayName': nameCtl.text.trim(),
      'displayNameLower': nameCtl.text.trim().toLowerCase(),
      'city': cityCtl.text.trim(),
      'sex': sex,
      'dob': dob != null ? dob!.toIso8601String() : null,
      'visitedCountries': visited.toList(),
    };
    if (localProfileImage != null) {
      upd['profileImageDataUrl'] = localProfileImage;
    }
    if (removeImage) {
      upd['profileImageDataUrl'] = FieldValue.delete();
    }
    upd.removeWhere((k, v) => v == null || (v is String && v.isEmpty));

    try {
      await docRef.set(upd, SetOptions(merge: true));
      if (localProfileImage != null) {
        // ignore: avoid_print
        print('Saved profileImageDataUrl length: ${localProfileImage!.length}');
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated')));
    } catch (err, st) {
      // ignore: avoid_print
      print('Failed to save profile: $err\n$st');
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save profile: $err')));
    }
  }

  // Country picker dialog returns the selected set or null if cancelled.
  Future<Set<String>?> _showCountryPicker(
    BuildContext context,
    Set<String> initial,
  ) async {
    final countries = _commonCountries;
    final selected = Set<String>.from(initial);
    return showDialog<Set<String>>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Select visited countries'),
          content: SizedBox(
            width: double.maxFinite,
            child: StatefulBuilder(
              builder: (ctx2, setState) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 320,
                      width: double.maxFinite,
                      child: SingleChildScrollView(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children:
                              countries.map((c) {
                                final isSel = selected.contains(c);
                                return FilterChip(
                                  selected: isSel,
                                  label: Text(c),
                                  onSelected:
                                      (v) => setState(
                                        () =>
                                            v
                                                ? selected.add(c)
                                                : selected.remove(c),
                                      ),
                                );
                              }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(null),
                          child: const Text('Cancel'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(selected),
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  // A short common country list for the picker. Extend as needed.
  static const List<String> _commonCountries = [
    'United States',
    'Canada',
    'Mexico',
    'United Kingdom',
    'France',
    'Germany',
    'Italy',
    'Spain',
    'Portugal',
    'Netherlands',
    'Belgium',
    'Switzerland',
    'Austria',
    'Ireland',
    'Sweden',
    'Norway',
    'Denmark',
    'Finland',
    'Iceland',
    'Poland',
    'Czech Republic',
    'Greece',
    'Turkey',
    'Russia',
    'China',
    'Japan',
    'South Korea',
    'India',
    'Australia',
    'New Zealand',
    'South Africa',
    'Morocco',
    'Egypt',
    'Kenya',
    'Argentina',
    'Brazil',
    'Chile',
    'Peru',
    'Colombia',
  ];
}
