import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:trypr/models/budget_person.dart';
import 'package:trypr/services/name_lookup.dart';
import 'package:trypr/utils/trypr_snackbar.dart';

class TripExpensesDialog {
  static const List<String> _categories = <String>[
    'Accommodation',
    'Food',
    'Transport',
    'Activities',
    'Groceries',
    'Shopping',
    'Other',
  ];

  static Future<void> show({
    required BuildContext context,
    required DocumentReference<Map<String, dynamic>> tripRef,
    required String currentUid,
    required List<String> participants,
  }) async {
    final nameCache = <String, String>{};
    await ensureNameCache(
      nameCache,
      participants,
      currentUidForFriendsFallback: currentUid,
    );
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final titleCtl = TextEditingController();
        final amountCtl = TextEditingController();
        final personCtl = TextEditingController();
        String viewMode = 'group';
        String splitMode = 'group';
        String? paidByPersonId =
            participants.contains(currentUid) ? currentUid : null;
        String category = 'Other';
        bool saving = false;
        bool personSaving = false;

        return StatefulBuilder(
          builder: (ctx2, setState2) {
            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: tripRef.snapshots(),
              builder: (ctxTrip, tripSnap) {
                final tripData =
                    tripSnap.data?.data() ?? const <String, dynamic>{};
                final tripBudget = tripData['tripBudget'];
                final customPeople =
                    tripBudget is Map
                        ? parseBudgetPeople(tripBudget['people'])
                        : const <BudgetPerson>[];
                final allPeople = mergeBudgetPeople(
                  participantUids: participants,
                  nameCache: nameCache,
                  customPeople: customPeople,
                );
                final resolvedPaidByPersonId = _resolvedPaidBySelection(
                  people: allPeople,
                  selectedId: paidByPersonId,
                  currentUid: currentUid,
                );
                final finalSplitByCount = _resolveFinalExpenseSplitCount(
                  raw:
                      tripBudget is Map
                          ? tripBudget['finalSplitByCount']
                          : null,
                  people: allPeople,
                );

                Future<void> addCustomPerson() async {
                  final name = personCtl.text.trim();
                  if (name.isEmpty || personSaving) return;
                  final exists = allPeople.any(
                    (person) =>
                        person.name.trim().toLowerCase() == name.toLowerCase(),
                  );
                  if (exists) {
                    ScaffoldMessenger.of(ctx2).showTryprSnackBar(
                      const SnackBar(
                        content: Text('That person already exists'),
                      ),
                    );
                    return;
                  }

                  setState2(() => personSaving = true);
                  try {
                    await tripRef.update({
                      'tripBudget.people': encodeBudgetPeople(<BudgetPerson>[
                        ...customPeople,
                        BudgetPerson.custom(name),
                      ]),
                    });
                    personCtl.clear();
                  } catch (e) {
                    if (ctx2.mounted) {
                      ScaffoldMessenger.of(ctx2).showTryprSnackBar(
                        SnackBar(content: Text('Could not add person: $e')),
                      );
                    }
                  } finally {
                    if (ctx2.mounted) {
                      setState2(() => personSaving = false);
                    }
                  }
                }

                Future<void> removeCustomPerson(BudgetPerson person) async {
                  if (personSaving) return;
                  setState2(() => personSaving = true);
                  try {
                    await tripRef.update({
                      'tripBudget.people': encodeBudgetPeople(
                        customPeople.where((entry) => entry.id != person.id),
                      ),
                    });
                    if (paidByPersonId == person.id) {
                      setState2(() => paidByPersonId = null);
                    }
                  } catch (e) {
                    if (ctx2.mounted) {
                      ScaffoldMessenger.of(ctx2).showTryprSnackBar(
                        SnackBar(content: Text('Could not remove person: $e')),
                      );
                    }
                  } finally {
                    if (ctx2.mounted) {
                      setState2(() => personSaving = false);
                    }
                  }
                }

                Future<void> updateFinalSplitByCount(int nextCount) async {
                  final normalized = math.max(1, nextCount);
                  try {
                    await tripRef.update({
                      'tripBudget.finalSplitByCount': normalized,
                    });
                  } catch (e) {
                    if (ctx2.mounted) {
                      ScaffoldMessenger.of(ctx2).showTryprSnackBar(
                        SnackBar(
                          content: Text('Could not update final split: $e'),
                        ),
                      );
                    }
                  }
                }

                Future<void> addExpense() async {
                  final title = titleCtl.text.trim();
                  final amountRaw = amountCtl.text.trim();
                  if (title.isEmpty) {
                    ScaffoldMessenger.of(ctx2).showTryprSnackBar(
                      const SnackBar(content: Text('Title is required')),
                    );
                    return;
                  }

                  final parsed = double.tryParse(amountRaw);
                  if (parsed == null || parsed <= 0) {
                    ScaffoldMessenger.of(ctx2).showTryprSnackBar(
                      const SnackBar(content: Text('Enter a valid amount > 0')),
                    );
                    return;
                  }

                  final payer = budgetPersonById(
                    allPeople,
                    resolvedPaidByPersonId,
                  );
                  setState2(() => saving = true);
                  try {
                    final payload = <String, dynamic>{
                      'title': title,
                      'amount': parsed,
                      'splitMode': splitMode,
                      'category': category,
                      'createdAt': Timestamp.now(),
                      'createdByUid': currentUid,
                    };

                    if (payer != null) {
                      payload['paidByPersonId'] = payer.id;
                      payload['paidByPersonName'] = payer.name;
                      if (payer.uid != null && payer.uid!.isNotEmpty) {
                        payload['paidByUid'] = payer.uid;
                      }
                    }

                    await tripRef.collection('expenses').add(payload);
                    titleCtl.clear();
                    amountCtl.clear();
                  } catch (e) {
                    if (ctx2.mounted) {
                      ScaffoldMessenger.of(ctx2).showTryprSnackBar(
                        SnackBar(content: Text('Add failed: $e')),
                      );
                    }
                  } finally {
                    if (ctx2.mounted) {
                      setState2(() => saving = false);
                    }
                  }
                }

                Future<bool> confirmDeleteExpense({
                  required BuildContext dialogContext,
                  required QueryDocumentSnapshot<Map<String, dynamic>> doc,
                }) async {
                  final ok = await showDialog<bool>(
                    context: dialogContext,
                    builder:
                        (c) => AlertDialog(
                          title: const Text('Delete expense?'),
                          content: const Text(
                            'This removes it for everyone on the trip.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(c).pop(false),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.of(c).pop(true),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                  );

                  if (ok != true) return false;

                  try {
                    await tripRef.collection('expenses').doc(doc.id).delete();
                    return true;
                  } catch (e) {
                    if (dialogContext.mounted) {
                      ScaffoldMessenger.of(dialogContext).showTryprSnackBar(
                        SnackBar(content: Text('Delete failed: $e')),
                      );
                    }
                    return false;
                  }
                }

                Future<void> editExpense(
                  QueryDocumentSnapshot<Map<String, dynamic>> doc,
                ) async {
                  final data = doc.data();
                  final editTitleCtl = TextEditingController(
                    text: (data['title'] ?? '').toString(),
                  );
                  final editAmountCtl = TextEditingController(
                    text:
                        ((data['amount'] as num?)?.toDouble() ?? 0.0)
                            .toString(),
                  );
                  String editSplitMode =
                      (data['splitMode'] ?? 'group').toString();
                  String? editPaidByPersonId = _expensePaidByPersonId(data);
                  String editCategory =
                      (data['category'] ?? 'Other').toString();
                  bool editSaving = false;

                  await showDialog<void>(
                    context: ctx2,
                    builder: (c) {
                      return StatefulBuilder(
                        builder: (c2, setState3) {
                          final editPeople = _expensePeopleForSelection(
                            people: allPeople,
                            selectedId: editPaidByPersonId,
                            fallbackName: _expensePaidByPersonName(data),
                          );
                          final resolvedEditPaidById = _resolvedPaidBySelection(
                            people: editPeople,
                            selectedId: editPaidByPersonId,
                            currentUid: currentUid,
                          );

                          Future<void> save() async {
                            final title = editTitleCtl.text.trim();
                            final amountRaw = editAmountCtl.text.trim();
                            final amount = double.tryParse(amountRaw);
                            if (title.isEmpty) {
                              ScaffoldMessenger.of(c2).showTryprSnackBar(
                                const SnackBar(
                                  content: Text('Title is required'),
                                ),
                              );
                              return;
                            }
                            if (amount == null || amount <= 0) {
                              ScaffoldMessenger.of(c2).showTryprSnackBar(
                                const SnackBar(
                                  content: Text('Enter a valid amount > 0'),
                                ),
                              );
                              return;
                            }

                            final payer = budgetPersonById(
                              editPeople,
                              resolvedEditPaidById,
                            );
                            setState3(() => editSaving = true);
                            try {
                              await tripRef
                                  .collection('expenses')
                                  .doc(doc.id)
                                  .update({
                                    'title': title,
                                    'amount': amount,
                                    'splitMode': editSplitMode,
                                    'splitByCount': FieldValue.delete(),
                                    'category': editCategory,
                                    if (payer != null) ...{
                                      'paidByPersonId': payer.id,
                                      'paidByPersonName': payer.name,
                                      if (payer.uid != null &&
                                          payer.uid!.isNotEmpty)
                                        'paidByUid': payer.uid
                                      else
                                        'paidByUid': FieldValue.delete(),
                                    } else ...{
                                      'paidByPersonId': FieldValue.delete(),
                                      'paidByPersonName': FieldValue.delete(),
                                      'paidByUid': FieldValue.delete(),
                                    },
                                  });
                              if (c2.mounted) Navigator.of(c2).pop();
                            } catch (e) {
                              if (c2.mounted) {
                                ScaffoldMessenger.of(c2).showTryprSnackBar(
                                  SnackBar(content: Text('Save failed: $e')),
                                );
                              }
                            } finally {
                              if (c2.mounted) {
                                setState3(() => editSaving = false);
                              }
                            }
                          }

                          Future<void> deleteFromEditor() async {
                            final deleted = await confirmDeleteExpense(
                              dialogContext: c2,
                              doc: doc,
                            );
                            if (deleted && c2.mounted) {
                              Navigator.of(c2).pop();
                            }
                          }

                          return AlertDialog(
                            title: const Text('Edit expense'),
                            content: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 640),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      ChoiceChip(
                                        label: const Text('Group split'),
                                        selected: editSplitMode == 'group',
                                        onSelected:
                                            editSaving
                                                ? null
                                                : (v) => setState3(
                                                  () => editSplitMode = 'group',
                                                ),
                                      ),
                                      const SizedBox(width: 8),
                                      ChoiceChip(
                                        label: const Text('Personal'),
                                        selected: editSplitMode == 'personal',
                                        onSelected:
                                            editSaving
                                                ? null
                                                : (v) => setState3(
                                                  () =>
                                                      editSplitMode =
                                                          'personal',
                                                ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: editTitleCtl,
                                    decoration: const InputDecoration(
                                      labelText: 'Expense',
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: editAmountCtl,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: const InputDecoration(
                                      labelText: 'Amount',
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: DropdownButtonFormField<String>(
                                          initialValue:
                                              _categories.contains(editCategory)
                                                  ? editCategory
                                                  : 'Other',
                                          items:
                                              _categories
                                                  .map(
                                                    (entry) => DropdownMenuItem<
                                                      String
                                                    >(
                                                      value: entry,
                                                      child: Text(entry),
                                                    ),
                                                  )
                                                  .toList(),
                                          onChanged:
                                              editSaving
                                                  ? null
                                                  : (value) => setState3(
                                                    () =>
                                                        editCategory =
                                                            value ?? 'Other',
                                                  ),
                                          decoration: const InputDecoration(
                                            labelText: 'Category',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: DropdownButtonFormField<String?>(
                                          initialValue: resolvedEditPaidById,
                                          items: [
                                            const DropdownMenuItem<String?>(
                                              value: null,
                                              child: Text('Unassigned'),
                                            ),
                                            ...editPeople.map(
                                              (person) =>
                                                  DropdownMenuItem<String?>(
                                                    value: person.id,
                                                    child: Text(person.name),
                                                  ),
                                            ),
                                          ],
                                          onChanged:
                                              editSaving
                                                  ? null
                                                  : (value) => setState3(
                                                    () =>
                                                        editPaidByPersonId =
                                                            value,
                                                  ),
                                          decoration: const InputDecoration(
                                            labelText: 'Paid by',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed:
                                    editSaving
                                        ? null
                                        : () => Navigator.of(c2).pop(),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: editSaving ? null : deleteFromEditor,
                                child: const Text('Delete'),
                              ),
                              ElevatedButton.icon(
                                onPressed: editSaving ? null : save,
                                icon:
                                    editSaving
                                        ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                        : const Icon(Icons.save),
                                label: const Text('Save'),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  );
                }

                return AlertDialog(
                  title: const Text('Expenses'),
                  content: SizedBox(
                    width:
                        (MediaQuery.sizeOf(ctx2).width - 32)
                            .clamp(0.0, 920.0)
                            .toDouble(),
                    height:
                        (MediaQuery.sizeOf(ctx2).height * 0.85)
                            .clamp(360.0, 760.0)
                            .toDouble(),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            ChoiceChip(
                              label: const Text('Group split'),
                              selected: viewMode == 'group',
                              onSelected:
                                  (v) => setState2(() {
                                    viewMode = 'group';
                                    splitMode = 'group';
                                  }),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Personal'),
                              selected: viewMode == 'personal',
                              onSelected:
                                  (v) => setState2(() {
                                    viewMode = 'personal';
                                    splitMode = 'personal';
                                  }),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.pie_chart_outline, size: 16),
                                  SizedBox(width: 6),
                                  Text('Group expenses'),
                                ],
                              ),
                              selected: viewMode == 'group_categories',
                              onSelected:
                                  (v) => setState2(() {
                                    viewMode = 'group_categories';
                                    splitMode = 'group';
                                  }),
                            ),
                            const Spacer(),
                            Text('People: ${allPeople.length}'),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final person in customPeople)
                                InputChip(
                                  label: Text(person.name),
                                  onDeleted:
                                      personSaving
                                          ? null
                                          : () => removeCustomPerson(person),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: personCtl,
                                decoration: const InputDecoration(
                                  labelText: 'Add person',
                                  hintText: 'Mom, Jake, Roommate...',
                                ),
                                onSubmitted:
                                    personSaving
                                        ? null
                                        : (_) => addCustomPerson(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton.icon(
                              onPressed: personSaving ? null : addCustomPerson,
                              icon:
                                  personSaving
                                      ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                      : const Icon(Icons.person_add_alt_1),
                              label: const Text('Add person'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            SizedBox(
                              width: 260,
                              child: TextField(
                                controller: titleCtl,
                                decoration: const InputDecoration(
                                  labelText: 'Expense',
                                  hintText: 'Gas, hotel, tickets...',
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 140,
                              child: TextField(
                                controller: amountCtl,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  labelText: 'Amount',
                                  hintText: '0.00',
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: DropdownButtonFormField<String?>(
                                isExpanded: true,
                                initialValue: resolvedPaidByPersonId,
                                items: [
                                  const DropdownMenuItem<String?>(
                                    value: null,
                                    child: Text('Unassigned'),
                                  ),
                                  ...allPeople.map(
                                    (person) => DropdownMenuItem<String?>(
                                      value: person.id,
                                      child: Text(
                                        person.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ],
                                onChanged:
                                    saving
                                        ? null
                                        : (value) => setState2(
                                          () => paidByPersonId = value,
                                        ),
                                decoration: const InputDecoration(
                                  labelText: 'Paid by',
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 160,
                              child: DropdownButtonFormField<String>(
                                isExpanded: true,
                                initialValue:
                                    _categories.contains(category)
                                        ? category
                                        : 'Other',
                                items:
                                    _categories
                                        .map(
                                          (entry) => DropdownMenuItem<String>(
                                            value: entry,
                                            child: Text(
                                              entry,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        )
                                        .toList(),
                                onChanged:
                                    saving
                                        ? null
                                        : (value) => setState2(
                                          () => category = value ?? 'Other',
                                        ),
                                decoration: const InputDecoration(
                                  labelText: 'Category',
                                ),
                              ),
                            ),
                            ElevatedButton.icon(
                              onPressed: saving ? null : addExpense,
                              icon:
                                  saving
                                      ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                      : const Icon(Icons.add),
                              label: const Text('Add'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: StreamBuilder<
                            QuerySnapshot<Map<String, dynamic>>
                          >(
                            stream:
                                tripRef
                                    .collection('expenses')
                                    .orderBy('createdAt', descending: true)
                                    .snapshots(),
                            builder: (ctx3, snap) {
                              if (snap.hasError) {
                                return Center(
                                  child: Text('Failed to load: ${snap.error}'),
                                );
                              }
                              if (!snap.hasData) {
                                return const Center(
                                  child: CircularProgressIndicator(),
                                );
                              }

                              final docs = snap.data!.docs;
                              if (docs.isEmpty) {
                                return const Center(
                                  child: Text('No expenses yet'),
                                );
                              }

                              final filtered =
                                  docs.where((doc) {
                                    final data = doc.data();
                                    final mode =
                                        (data['splitMode'] ?? 'group')
                                            .toString();
                                    if (viewMode == 'personal') {
                                      return mode == 'personal';
                                    }
                                    return mode != 'personal';
                                  }).toList();

                              if (filtered.isEmpty) {
                                return Center(
                                  child: Text(
                                    viewMode == 'personal'
                                        ? 'No personal expenses yet'
                                        : 'No group expenses yet',
                                  ),
                                );
                              }

                              final expensePeople = _expensePeopleForDocs(
                                people: allPeople,
                                docs: filtered,
                              );
                              final totalGroupAmount = filtered.fold<double>(
                                0,
                                (runningTotal, doc) =>
                                    runningTotal +
                                    ((doc.data()['amount'] as num?)
                                            ?.toDouble() ??
                                        0.0),
                              );

                              Widget buildFinalSplitSummary() {
                                if (viewMode == 'personal') {
                                  return const SizedBox.shrink();
                                }
                                final eachShare =
                                    finalSplitByCount <= 0
                                        ? 0.0
                                        : totalGroupAmount / finalSplitByCount;
                                return _FinalSplitSummaryCard(
                                  splitByCount: finalSplitByCount,
                                  totalAmount: totalGroupAmount,
                                  eachShare: eachShare,
                                  onDecrease:
                                      finalSplitByCount <= 1
                                          ? null
                                          : () => updateFinalSplitByCount(
                                            finalSplitByCount - 1,
                                          ),
                                  onIncrease:
                                      () => updateFinalSplitByCount(
                                        finalSplitByCount + 1,
                                      ),
                                );
                              }

                              if (viewMode == 'group_categories') {
                                final byCategory = <String, double>{};
                                for (final doc in filtered) {
                                  final data = doc.data();
                                  final amount =
                                      (data['amount'] as num?)?.toDouble() ??
                                      0.0;
                                  if (amount <= 0) continue;
                                  final cat =
                                      (data['category'] ?? 'Other').toString();
                                  byCategory[cat] =
                                      (byCategory[cat] ?? 0) + amount;
                                }

                                final orderedCats =
                                    byCategory.entries.toList()..sort(
                                      (a, b) => b.value.compareTo(a.value),
                                    );

                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 220,
                                      height: 220,
                                      child: _PieChart(
                                        segments:
                                            orderedCats
                                                .map(
                                                  (entry) => _PieSegment(
                                                    label: entry.key,
                                                    value: entry.value,
                                                  ),
                                                )
                                                .toList(),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Group expenses by category',
                                            style: Theme.of(
                                              ctx3,
                                            ).textTheme.titleSmall?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          buildFinalSplitSummary(),
                                          const SizedBox(height: 10),
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 6,
                                            children:
                                                orderedCats
                                                    .map(
                                                      (entry) => Chip(
                                                        label: Text(
                                                          '${entry.key}: ${entry.value.toStringAsFixed(2)}',
                                                        ),
                                                      ),
                                                    )
                                                    .toList(),
                                          ),
                                          const SizedBox(height: 10),
                                          Expanded(
                                            child: ListView.separated(
                                              itemCount: filtered.length,
                                              separatorBuilder:
                                                  (_, __) =>
                                                      const Divider(height: 1),
                                              itemBuilder: (ctx4, index) {
                                                final doc = filtered[index];
                                                final data = doc.data();
                                                final title =
                                                    (data['title'] ?? '')
                                                        .toString();
                                                final amount =
                                                    (data['amount'] as num?)
                                                        ?.toDouble() ??
                                                    0.0;
                                                final paidById =
                                                    _expensePaidByPersonId(
                                                      data,
                                                    );
                                                final paidByName =
                                                    budgetPersonLabelForId(
                                                      people: expensePeople,
                                                      id: paidById,
                                                      fallbackName:
                                                          _expensePaidByPersonName(
                                                            data,
                                                          ),
                                                    );
                                                final cat =
                                                    (data['category'] ??
                                                            'Other')
                                                        .toString();
                                                final when = _expenseDate(data);

                                                return ListTile(
                                                  dense: true,
                                                  title: Text(title),
                                                  subtitle: Text(
                                                    '${cat.isEmpty ? 'Other' : cat} • Paid by $paidByName${when == null ? '' : ' • ${_fmtWhen(when)}'}',
                                                  ),
                                                  trailing: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Text(
                                                        amount.toStringAsFixed(
                                                          2,
                                                        ),
                                                      ),
                                                      IconButton(
                                                        tooltip: 'Delete',
                                                        onPressed: () async {
                                                          await confirmDeleteExpense(
                                                            dialogContext: ctx4,
                                                            doc: doc,
                                                          );
                                                        },
                                                        icon: const Icon(
                                                          Icons.delete_outline,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  onTap: () async {
                                                    await ensureNameCache(
                                                      nameCache,
                                                      participants,
                                                      currentUidForFriendsFallback:
                                                          currentUid,
                                                    );
                                                    if (!ctx4.mounted) return;
                                                    await editExpense(doc);
                                                  },
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                );
                              }

                              final totals = <String, double>{
                                for (final person in expensePeople)
                                  person.id: 0,
                              };
                              final myByCategory = <String, double>{};

                              for (final doc in filtered) {
                                final data = doc.data();
                                final amount =
                                    (data['amount'] as num?)?.toDouble() ?? 0.0;
                                final paidById = _expensePaidByPersonId(data);
                                final cat =
                                    (data['category'] ?? 'Other').toString();

                                if (amount <= 0) continue;

                                final payerId = paidById ?? '';
                                if (payerId.isNotEmpty) {
                                  totals[payerId] =
                                      (totals[payerId] ?? 0) + amount;
                                }

                                if (viewMode == 'personal') {
                                  if (paidById == currentUid) {
                                    myByCategory[cat] =
                                        (myByCategory[cat] ?? 0) + amount;
                                  }
                                } else if (participants.contains(currentUid)) {
                                  myByCategory[cat] =
                                      (myByCategory[cat] ?? 0) +
                                      (amount / finalSplitByCount);
                                }
                              }

                              final totalPaid = totals.values.fold<double>(
                                0,
                                (total, value) => total + value,
                              );
                              final orderedPeople =
                                  expensePeople.toList()..sort(
                                    (a, b) => (totals[b.id] ?? 0).compareTo(
                                      totals[a.id] ?? 0,
                                    ),
                                  );

                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 220,
                                    height: 220,
                                    child: _PieChart(
                                      segments:
                                          orderedPeople
                                              .map(
                                                (person) => _PieSegment(
                                                  label: person.name,
                                                  value: totals[person.id] ?? 0,
                                                ),
                                              )
                                              .toList(),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          viewMode == 'personal'
                                              ? 'Personal paid breakdown'
                                              : 'Paid breakdown',
                                          style: Theme.of(
                                            ctx3,
                                          ).textTheme.titleSmall?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        if (viewMode != 'personal') ...[
                                          buildFinalSplitSummary(),
                                          const SizedBox(height: 10),
                                        ],
                                        SizedBox(
                                          height: 94,
                                          child: ListView.builder(
                                            itemCount: orderedPeople.length,
                                            itemBuilder: (ctx4, index) {
                                              final person =
                                                  orderedPeople[index];
                                              final value =
                                                  totals[person.id] ?? 0;
                                              final pct =
                                                  totalPaid <= 0
                                                      ? 0.0
                                                      : (value / totalPaid) *
                                                          100.0;
                                              return Padding(
                                                padding: const EdgeInsets.only(
                                                  bottom: 6,
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      person.name,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: Theme.of(ctx3)
                                                          .textTheme
                                                          .bodyMedium
                                                          ?.copyWith(
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                    ),
                                                    Text(
                                                      '${pct.toStringAsFixed(0)}% • ${value.toStringAsFixed(2)}',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: Theme.of(ctx3)
                                                          .textTheme
                                                          .bodySmall
                                                          ?.copyWith(
                                                            color:
                                                                Colors.black54,
                                                          ),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        if (myByCategory.isNotEmpty) ...[
                                          Text(
                                            'Your breakdown',
                                            style: Theme.of(
                                              ctx3,
                                            ).textTheme.titleSmall?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 6,
                                            children:
                                                (myByCategory.entries.toList()
                                                      ..sort(
                                                        (a, b) => b.value
                                                            .compareTo(a.value),
                                                      ))
                                                    .map(
                                                      (entry) => Chip(
                                                        label: Text(
                                                          '${entry.key}: ${entry.value.toStringAsFixed(2)}',
                                                        ),
                                                      ),
                                                    )
                                                    .toList(),
                                          ),
                                          const SizedBox(height: 10),
                                        ],
                                        Expanded(
                                          child: ListView.separated(
                                            itemCount: filtered.length,
                                            separatorBuilder:
                                                (_, __) =>
                                                    const Divider(height: 1),
                                            itemBuilder: (ctx4, index) {
                                              final doc = filtered[index];
                                              final data = doc.data();
                                              final title =
                                                  (data['title'] ?? '')
                                                      .toString();
                                              final amount =
                                                  (data['amount'] as num?)
                                                      ?.toDouble() ??
                                                  0.0;
                                              final mode =
                                                  (data['splitMode'] ?? 'group')
                                                      .toString();
                                              final paidById =
                                                  _expensePaidByPersonId(data);
                                              final paidByName =
                                                  budgetPersonLabelForId(
                                                    people: expensePeople,
                                                    id: paidById,
                                                    fallbackName:
                                                        _expensePaidByPersonName(
                                                          data,
                                                        ),
                                                  );
                                              final cat =
                                                  (data['category'] ?? 'Other')
                                                      .toString();
                                              final when = _expenseDate(data);

                                              return ListTile(
                                                dense: true,
                                                title: Text(title),
                                                subtitle: Text(
                                                  '${mode == 'personal' ? 'Personal' : 'Group'} • ${cat.isEmpty ? 'Other' : cat} • Paid by $paidByName${when == null ? '' : ' • ${_fmtWhen(when)}'}',
                                                ),
                                                trailing: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      amount.toStringAsFixed(2),
                                                    ),
                                                    IconButton(
                                                      tooltip: 'Delete',
                                                      onPressed: () async {
                                                        await confirmDeleteExpense(
                                                          dialogContext: ctx4,
                                                          doc: doc,
                                                        );
                                                      },
                                                      icon: const Icon(
                                                        Icons.delete_outline,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                onTap: () async {
                                                  await ensureNameCache(
                                                    nameCache,
                                                    participants,
                                                    currentUidForFriendsFallback:
                                                        currentUid,
                                                  );
                                                  if (!ctx4.mounted) return;
                                                  await editExpense(doc);
                                                },
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
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
      },
    );
  }
}

String _fmtWhen(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

DateTime? _expenseDate(Map<String, dynamic> data) {
  final raw = data['createdAt'];
  if (raw is Timestamp) return raw.toDate();
  return null;
}

String? _expensePaidByPersonId(Map<String, dynamic> data) {
  final personId = (data['paidByPersonId'] ?? '').toString().trim();
  if (personId.isNotEmpty) return personId;
  final uid = (data['paidByUid'] ?? '').toString().trim();
  return uid.isEmpty ? null : uid;
}

String _expensePaidByPersonName(Map<String, dynamic> data) {
  return (data['paidByPersonName'] ?? '').toString().trim();
}

int _resolveFinalExpenseSplitCount({
  required dynamic raw,
  required List<BudgetPerson> people,
}) {
  if (raw is int && raw > 0) return raw;
  if (raw is num && raw > 0) return raw.round();
  final parsed = int.tryParse(raw?.toString() ?? '');
  if (parsed != null && parsed > 0) return parsed;
  return math.max(1, people.length);
}

String? _resolvedPaidBySelection({
  required List<BudgetPerson> people,
  required String? selectedId,
  required String currentUid,
}) {
  final trimmedSelectedId = (selectedId ?? '').trim();
  if (trimmedSelectedId.isNotEmpty &&
      budgetPersonById(people, trimmedSelectedId) != null) {
    return trimmedSelectedId;
  }
  if (currentUid.trim().isNotEmpty &&
      budgetPersonById(people, currentUid) != null) {
    return currentUid;
  }
  return null;
}

List<BudgetPerson> _expensePeopleForSelection({
  required List<BudgetPerson> people,
  required String? selectedId,
  String? fallbackName,
}) {
  final trimmedSelectedId = (selectedId ?? '').trim();
  if (trimmedSelectedId.isEmpty ||
      budgetPersonById(people, trimmedSelectedId) != null) {
    return people;
  }

  return <BudgetPerson>[
    ...people,
    BudgetPerson.custom(
      (fallbackName ?? '').trim().isNotEmpty
          ? fallbackName!.trim()
          : trimmedSelectedId,
      id: trimmedSelectedId,
    ),
  ];
}

List<BudgetPerson> _expensePeopleForDocs({
  required List<BudgetPerson> people,
  required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
}) {
  var resolved = people;
  for (final doc in docs) {
    final data = doc.data();
    resolved = _expensePeopleForSelection(
      people: resolved,
      selectedId: _expensePaidByPersonId(data),
      fallbackName: _expensePaidByPersonName(data),
    );
  }
  return resolved;
}

class _FinalSplitSummaryCard extends StatelessWidget {
  final int splitByCount;
  final double totalAmount;
  final double eachShare;
  final VoidCallback? onDecrease;
  final VoidCallback onIncrease;

  const _FinalSplitSummaryCard({
    required this.splitByCount,
    required this.totalAmount,
    required this.eachShare,
    required this.onDecrease,
    required this.onIncrease,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x14000000)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Final split',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Split total by'),
              const SizedBox(width: 8),
              IconButton(
                onPressed: onDecrease,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Container(
                constraints: const BoxConstraints(minWidth: 42),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0x14000000)),
                ),
                child: Text(
                  '$splitByCount',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: onIncrease,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Total ${totalAmount.toStringAsFixed(2)} • Each ${eachShare.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF4B5563),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PieSegment {
  final String label;
  final double value;

  _PieSegment({required this.label, required this.value});
}

class _PieChart extends StatelessWidget {
  final List<_PieSegment> segments;

  const _PieChart({required this.segments});

  @override
  Widget build(BuildContext context) {
    final nonZero = segments.where((s) => s.value > 0).toList();
    if (nonZero.isEmpty) {
      return const Center(child: Text('No data'));
    }
    return CustomPaint(
      painter: _PiePainter(nonZero),
      child: const SizedBox.expand(),
    );
  }
}

class _PiePainter extends CustomPainter {
  final List<_PieSegment> segments;

  _PiePainter(this.segments);

  @override
  void paint(Canvas canvas, Size size) {
    final total = segments.fold<double>(
      0,
      (runningTotal, s) => runningTotal + s.value,
    );
    if (total <= 0) return;

    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = math.min(size.width, size.height) / 2;

    final paint = Paint()..style = PaintingStyle.fill;
    double start = -math.pi / 2;

    for (var i = 0; i < segments.length; i++) {
      final sweep = (segments[i].value / total) * math.pi * 2;
      paint.color = _palette[i % _palette.length];
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        true,
        paint,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PiePainter oldDelegate) {
    if (oldDelegate.segments.length != segments.length) return true;
    for (var i = 0; i < segments.length; i++) {
      if (oldDelegate.segments[i].label != segments[i].label) return true;
      if (oldDelegate.segments[i].value != segments[i].value) return true;
    }
    return false;
  }
}

const List<Color> _palette = <Color>[
  Color(0xFF4E79A7),
  Color(0xFFF28E2B),
  Color(0xFFE15759),
  Color(0xFF76B7B2),
  Color(0xFF59A14F),
  Color(0xFFEDC948),
  Color(0xFFB07AA1),
  Color(0xFFFF9DA7),
  Color(0xFF9C755F),
  Color(0xFFBAB0AC),
];
