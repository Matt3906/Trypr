import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:trypr/widgets/top_taskbar.dart';

class CompleteProfileScreen extends StatefulWidget {
  const CompleteProfileScreen({super.key});

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  final _nameCtl = TextEditingController();
  final _cityCtl = TextEditingController();
  DateTime? _dob;
  String _sex = 'male';
  final Set<String> _visited = {};
  bool _saving = false;

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void dispose() {
    _nameCtl.dispose();
    _cityCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final uid = _user?.uid;
    if (uid == null) return;
    if (_nameCtl.text.trim().isEmpty || _cityCtl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill name and city')),
      );
      return;
    }
    setState(() => _saving = true);
    final upd = <String, dynamic>{
      'name': _nameCtl.text.trim(),
      'displayName': _nameCtl.text.trim(),
      'displayNameLower': _nameCtl.text.trim().toLowerCase(),
      'city': _cityCtl.text.trim(),
      'sex': _sex,
      'dob': _dob?.toIso8601String(),
      'visitedCountries': _visited.toList(),
    }..removeWhere((k, v) => v == null || (v is String && v.isEmpty));

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .set(upd, SetOptions(merge: true));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
      // Ensure saving flag is cleared and return early since write failed.
      if (mounted) setState(() => _saving = false);
      return;
    }

    // Write succeeded. Show success, then attempt navigation. Any navigation
    // errors should not be reported as a save failure since the data is already
    // persisted.
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile completed')));
    }

    try {
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/account');
    } catch (e, st) {
      // Navigation failed after successful save — log for debugging but do not
      // present this as a save failure to the user.
      if (kDebugMode) {
        // ignore: avoid_print
        print('Navigation failed after profile save: $e\n$st');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved but navigation failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 25),
      firstDate: DateTime(1900),
      lastDate: DateTime(now.year),
    );
    if (picked != null && mounted) setState(() => _dob = picked);
  }

  Future<void> _editVisited() async {
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) {
        final selected = Set<String>.from(_visited);
        return AlertDialog(
          title: const Text('Visited countries'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children:
                    _commonCountries.map((c) {
                      final sel = selected.contains(c);
                      return FilterChip(
                        selected: sel,
                        label: Text(c),
                        onSelected:
                            (v) => setState(() {
                              if (v) {
                                selected.add(c);
                              } else {
                                selected.remove(c);
                              }
                            }),
                      );
                    }).toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(selected),
              child: const Text('Done'),
            ),
          ],
        );
      },
    );
    if (result != null && mounted) {
      setState(() {
        _visited.clear();
        _visited.addAll(result);
      });
    }
  }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Complete your profile',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _nameCtl,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _cityCtl,
                    decoration: const InputDecoration(labelText: 'City'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: InputDecorator(
                          decoration: const InputDecoration(labelText: 'Sex'),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _sex,
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
                              onChanged: (v) {
                                if (v != null && mounted) {
                                  setState(() => _sex = v);
                                }
                              },
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
                            onTap: _pickDob,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 12.0,
                              ),
                              child: Text(
                                _dob != null
                                    ? '${_dob!.year}-${_dob!.month.toString().padLeft(2, '0')}-${_dob!.day.toString().padLeft(2, '0')}'
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
                        onPressed: _editVisited,
                        child: const Text('Edit'),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children:
                        _visited.map((c) => Chip(label: Text(c))).toList(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _saving ? null : _save,
                          child:
                              _saving
                                  ? const CircularProgressIndicator()
                                  : const Text('Save'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Skip'),
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
}
