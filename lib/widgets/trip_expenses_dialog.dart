import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:trypr/services/name_lookup.dart';

class TripExpensesDialog {
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

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final titleCtl = TextEditingController();
        final amountCtl = TextEditingController();
        String viewMode = 'group'; // 'group' | 'personal' | 'group_categories'
        String splitMode = 'group';
        String paidBy = currentUid;
        String category = 'Other';
        bool saving = false;

        final categories = <String>[
          'Accommodation',
          'Food',
          'Transport',
          'Activities',
          'Groceries',
          'Shopping',
          'Other',
        ];

        final payerOptions = <String>['', ...participants];

        return StatefulBuilder(
          builder: (ctx2, setState2) {
            Future<void> addExpense() async {
              final title = titleCtl.text.trim();
              final amountRaw = amountCtl.text.trim();
              if (title.isEmpty) {
                ScaffoldMessenger.of(ctx2).showSnackBar(
                  const SnackBar(content: Text('Title is required')),
                );
                return;
              }
              final parsed = double.tryParse(amountRaw);
              if (parsed == null || parsed <= 0) {
                ScaffoldMessenger.of(ctx2).showSnackBar(
                  const SnackBar(content: Text('Enter a valid amount > 0')),
                );
                return;
              }
              setState2(() => saving = true);
              try {
                await tripRef.collection('expenses').add({
                  'title': title,
                  'amount': parsed,
                  if (paidBy.isNotEmpty) 'paidByUid': paidBy,
                  'splitMode': splitMode, // 'group' | 'personal'
                  'category': category,
                  'createdAt': Timestamp.now(),
                  'createdByUid': currentUid,
                });
                titleCtl.clear();
                amountCtl.clear();
              } catch (e) {
                ScaffoldMessenger.of(
                  ctx2,
                ).showSnackBar(SnackBar(content: Text('Add failed: $e')));
              } finally {
                setState2(() => saving = false);
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
                text: ((data['amount'] as num?)?.toDouble() ?? 0.0).toString(),
              );
              String editSplitMode = (data['splitMode'] ?? 'group').toString();
              String editPaidBy = (data['paidByUid'] ?? '').toString();
              String editCategory = (data['category'] ?? 'Other').toString();
              bool editSaving = false;

              await showDialog<void>(
                context: ctx2,
                builder: (c) {
                  return StatefulBuilder(
                    builder: (c2, setState3) {
                      Future<void> save() async {
                        final t = editTitleCtl.text.trim();
                        final aRaw = editAmountCtl.text.trim();
                        final a = double.tryParse(aRaw);
                        if (t.isEmpty) {
                          ScaffoldMessenger.of(c2).showSnackBar(
                            const SnackBar(content: Text('Title is required')),
                          );
                          return;
                        }
                        if (a == null || a <= 0) {
                          ScaffoldMessenger.of(c2).showSnackBar(
                            const SnackBar(
                              content: Text('Enter a valid amount > 0'),
                            ),
                          );
                          return;
                        }
                        setState3(() => editSaving = true);
                        try {
                          await tripRef
                              .collection('expenses')
                              .doc(doc.id)
                              .update({
                                'title': t,
                                'amount': a,
                                'splitMode': editSplitMode,
                                'category': editCategory,
                                if (editPaidBy.isNotEmpty)
                                  'paidByUid': editPaidBy
                                else
                                  'paidByUid': FieldValue.delete(),
                              });
                          if (c2.mounted) Navigator.of(c2).pop();
                        } catch (e) {
                          if (c2.mounted) {
                            ScaffoldMessenger.of(c2).showSnackBar(
                              SnackBar(content: Text('Save failed: $e')),
                            );
                          }
                        } finally {
                          if (c2.mounted) setState3(() => editSaving = false);
                        }
                      }

                      return AlertDialog(
                        title: const Text('Edit expense'),
                        content: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  ChoiceChip(
                                    label: const Text('Group split'),
                                    selected: editSplitMode == 'group',
                                    onSelected:
                                        (v) => setState3(
                                          () => editSplitMode = 'group',
                                        ),
                                  ),
                                  const SizedBox(width: 8),
                                  ChoiceChip(
                                    label: const Text('Personal'),
                                    selected: editSplitMode == 'personal',
                                    onSelected:
                                        (v) => setState3(
                                          () => editSplitMode = 'personal',
                                        ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
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
                                      value:
                                          categories.contains(editCategory)
                                              ? editCategory
                                              : 'Other',
                                      items:
                                          categories
                                              .map(
                                                (c) => DropdownMenuItem<String>(
                                                  value: c,
                                                  child: Text(c),
                                                ),
                                              )
                                              .toList(),
                                      onChanged:
                                          editSaving
                                              ? null
                                              : (v) => setState3(
                                                () =>
                                                    editCategory = v ?? 'Other',
                                              ),
                                      decoration: const InputDecoration(
                                        labelText: 'Category',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      value:
                                          payerOptions.contains(editPaidBy)
                                              ? editPaidBy
                                              : '',
                                      items:
                                          payerOptions
                                              .map(
                                                (uid) =>
                                                    DropdownMenuItem<String>(
                                                      value: uid,
                                                      child: Text(
                                                        uid.isEmpty
                                                            ? 'Unassigned'
                                                            : (nameCache[uid] ??
                                                                uid),
                                                      ),
                                                    ),
                                              )
                                              .toList(),
                                      onChanged:
                                          editSaving
                                              ? null
                                              : (v) => setState3(
                                                () =>
                                                    editPaidBy =
                                                        v ?? editPaidBy,
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
                        Text('People: ${participants.length}'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: titleCtl,
                            decoration: const InputDecoration(
                              labelText: 'Expense',
                              hintText: 'Gas, hotel, tickets…',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: amountCtl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Amount',
                              hintText: '0.00',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: payerOptions.contains(paidBy) ? paidBy : '',
                            items:
                                payerOptions
                                    .map(
                                      (uid) => DropdownMenuItem<String>(
                                        value: uid,
                                        child: Text(
                                          uid.isEmpty
                                              ? 'Unassigned'
                                              : (nameCache[uid] ?? uid),
                                        ),
                                      ),
                                    )
                                    .toList(),
                            onChanged:
                                saving
                                    ? null
                                    : (v) =>
                                        setState2(() => paidBy = v ?? paidBy),
                            decoration: const InputDecoration(
                              labelText: 'Paid by',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value:
                                categories.contains(category)
                                    ? category
                                    : 'Other',
                            items:
                                categories
                                    .map(
                                      (c) => DropdownMenuItem<String>(
                                        value: c,
                                        child: Text(c),
                                      ),
                                    )
                                    .toList(),
                            onChanged:
                                saving
                                    ? null
                                    : (v) => setState2(
                                      () => category = v ?? 'Other',
                                    ),
                            decoration: const InputDecoration(
                              labelText: 'Category',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
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
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
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
                            return const Center(child: Text('No expenses yet'));
                          }

                          final filtered =
                              docs.where((d) {
                                final data = d.data();
                                final mode =
                                    (data['splitMode'] ?? 'group').toString();
                                if (viewMode == 'personal') {
                                  return mode == 'personal';
                                }
                                // group + group_categories
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

                          if (viewMode == 'group_categories') {
                            final byCategory = <String, double>{};
                            for (final d in filtered) {
                              final data = d.data();
                              final amount =
                                  (data['amount'] as num?)?.toDouble() ?? 0.0;
                              if (amount <= 0) continue;
                              final cat =
                                  (data['category'] ?? 'Other').toString();
                              byCategory[cat] = (byCategory[cat] ?? 0) + amount;
                            }

                            final orderedCats =
                                (byCategory.entries.toList()
                                  ..sort((a, b) => b.value.compareTo(a.value)));

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
                                              (e) => _PieSegment(
                                                label: e.key,
                                                value: e.value,
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
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children:
                                            orderedCats
                                                .map(
                                                  (e) => Chip(
                                                    label: Text(
                                                      '${e.key}: ${e.value.toStringAsFixed(2)}',
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
                                          itemBuilder: (ctx4, i) {
                                            final d = filtered[i];
                                            final data = d.data();
                                            final title =
                                                (data['title'] ?? '')
                                                    .toString();
                                            final amount =
                                                (data['amount'] as num?)
                                                    ?.toDouble() ??
                                                0.0;
                                            final paidByUid =
                                                (data['paidByUid'] ?? '')
                                                    .toString();
                                            final cat =
                                                (data['category'] ?? 'Other')
                                                    .toString();
                                            final ts = data['createdAt'];
                                            final when =
                                                ts is Timestamp
                                                    ? ts.toDate()
                                                    : null;

                                            return ListTile(
                                              dense: true,
                                              title: Text(title),
                                              subtitle: Text(
                                                '${cat.isEmpty ? 'Other' : cat} • Paid by ${paidByUid.isEmpty ? '—' : (nameCache[paidByUid] ?? paidByUid)}${when == null ? '' : ' • ${_fmtWhen(when)}'}',
                                              ),
                                              trailing: Text(
                                                amount.toStringAsFixed(2),
                                              ),
                                              onTap: () async {
                                                await ensureNameCache(
                                                  nameCache,
                                                  participants,
                                                  currentUidForFriendsFallback:
                                                      currentUid,
                                                );
                                                if (!ctx4.mounted) return;
                                                await editExpense(d);
                                              },
                                              onLongPress: () async {
                                                final ok = await showDialog<
                                                  bool
                                                >(
                                                  context: ctx4,
                                                  builder:
                                                      (c) => AlertDialog(
                                                        title: const Text(
                                                          'Delete expense?',
                                                        ),
                                                        content: const Text(
                                                          'This removes it for everyone on the trip.',
                                                        ),
                                                        actions: [
                                                          TextButton(
                                                            onPressed:
                                                                () =>
                                                                    Navigator.of(
                                                                      c,
                                                                    ).pop(
                                                                      false,
                                                                    ),
                                                            child: const Text(
                                                              'Cancel',
                                                            ),
                                                          ),
                                                          ElevatedButton(
                                                            onPressed:
                                                                () =>
                                                                    Navigator.of(
                                                                      c,
                                                                    ).pop(true),
                                                            child: const Text(
                                                              'Delete',
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                );
                                                if (ok == true) {
                                                  try {
                                                    await tripRef
                                                        .collection('expenses')
                                                        .doc(d.id)
                                                        .delete();
                                                  } catch (e) {
                                                    ScaffoldMessenger.of(
                                                      ctx4,
                                                    ).showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          'Delete failed: $e',
                                                        ),
                                                      ),
                                                    );
                                                  }
                                                }
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
                            for (final uid in participants) uid: 0,
                          };

                          final myByCategory = <String, double>{};

                          for (final d in filtered) {
                            final data = d.data();
                            final amount =
                                (data['amount'] as num?)?.toDouble() ?? 0.0;
                            final paidByUid =
                                (data['paidByUid'] ?? '').toString();
                            final cat =
                                (data['category'] ?? 'Other').toString();

                            if (amount <= 0) continue;

                            if (viewMode == 'personal') {
                              if (totals.containsKey(paidByUid)) {
                                totals[paidByUid] =
                                    (totals[paidByUid] ?? 0) + amount;
                              }
                              if (paidByUid == currentUid) {
                                myByCategory[cat] =
                                    (myByCategory[cat] ?? 0) + amount;
                              }
                            } else {
                              // Group split view: show who paid what % of group expenses.
                              if (totals.containsKey(paidByUid)) {
                                totals[paidByUid] =
                                    (totals[paidByUid] ?? 0) + amount;
                              }

                              // Keep a personal-by-category breakdown based on your equal share.
                              final n =
                                  participants.isEmpty
                                      ? 1
                                      : participants.length;
                              final share = amount / n;
                              if (participants.contains(currentUid)) {
                                myByCategory[cat] =
                                    (myByCategory[cat] ?? 0) + share;
                              }
                            }
                          }

                          final totalPaid = totals.values.fold<double>(
                            0,
                            (sum, v) => sum + v,
                          );
                          final orderedParticipants =
                              participants.toList()..sort(
                                (a, b) =>
                                    (totals[b] ?? 0).compareTo(totals[a] ?? 0),
                              );

                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 220,
                                height: 220,
                                child: _PieChart(
                                  segments:
                                      orderedParticipants
                                          .map(
                                            (uid) => _PieSegment(
                                              label: nameCache[uid] ?? uid,
                                              value: totals[uid] ?? 0,
                                            ),
                                          )
                                          .toList(),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      viewMode == 'personal'
                                          ? 'Personal paid breakdown'
                                          : 'Paid breakdown (keep it ~50/50)',
                                      style: Theme.of(
                                        ctx3,
                                      ).textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    SizedBox(
                                      height: 94,
                                      child: ListView.builder(
                                        itemCount: orderedParticipants.length,
                                        itemBuilder: (ctx, i) {
                                          final uid = orderedParticipants[i];
                                          final v = totals[uid] ?? 0;
                                          final pct =
                                              totalPaid <= 0
                                                  ? 0.0
                                                  : (v / totalPaid) * 100.0;
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 6,
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  nameCache[uid] ?? uid,
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
                                                  '${pct.toStringAsFixed(0)}% • ${v.toStringAsFixed(2)}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(ctx3)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: Colors.black54,
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
                                                    (a, b) => b.value.compareTo(
                                                      a.value,
                                                    ),
                                                  ))
                                                .map(
                                                  (e) => Chip(
                                                    label: Text(
                                                      '${e.key}: ${e.value.toStringAsFixed(2)}',
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
                                            (_, __) => const Divider(height: 1),
                                        itemBuilder: (ctx4, i) {
                                          final d = filtered[i];
                                          final data = d.data();
                                          final title =
                                              (data['title'] ?? '').toString();
                                          final amount =
                                              (data['amount'] as num?)
                                                  ?.toDouble() ??
                                              0.0;
                                          final mode =
                                              (data['splitMode'] ?? 'group')
                                                  .toString();
                                          final paidByUid =
                                              (data['paidByUid'] ?? '')
                                                  .toString();
                                          final cat =
                                              (data['category'] ?? 'Other')
                                                  .toString();
                                          final ts = data['createdAt'];
                                          final when =
                                              ts is Timestamp
                                                  ? ts.toDate()
                                                  : null;

                                          return ListTile(
                                            dense: true,
                                            title: Text(title),
                                            subtitle: Text(
                                              '${mode == 'personal' ? 'Personal' : 'Group'} • ${cat.isEmpty ? 'Other' : cat} • Paid by ${paidByUid.isEmpty ? '—' : (nameCache[paidByUid] ?? paidByUid)}${when == null ? '' : ' • ${_fmtWhen(when)}'}',
                                            ),
                                            trailing: Text(
                                              amount.toStringAsFixed(2),
                                            ),
                                            onTap: () async {
                                              // Ensure names are available before opening editor.
                                              await ensureNameCache(
                                                nameCache,
                                                participants,
                                                currentUidForFriendsFallback:
                                                    currentUid,
                                              );
                                              if (!ctx4.mounted) return;
                                              await editExpense(d);
                                            },
                                            onLongPress: () async {
                                              final ok = await showDialog<bool>(
                                                context: ctx4,
                                                builder:
                                                    (c) => AlertDialog(
                                                      title: const Text(
                                                        'Delete expense?',
                                                      ),
                                                      content: const Text(
                                                        'This removes it for everyone on the trip.',
                                                      ),
                                                      actions: [
                                                        TextButton(
                                                          onPressed:
                                                              () =>
                                                                  Navigator.of(
                                                                    c,
                                                                  ).pop(false),
                                                          child: const Text(
                                                            'Cancel',
                                                          ),
                                                        ),
                                                        ElevatedButton(
                                                          onPressed:
                                                              () =>
                                                                  Navigator.of(
                                                                    c,
                                                                  ).pop(true),
                                                          child: const Text(
                                                            'Delete',
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                              );
                                              if (ok == true) {
                                                try {
                                                  await tripRef
                                                      .collection('expenses')
                                                      .doc(d.id)
                                                      .delete();
                                                } catch (e) {
                                                  ScaffoldMessenger.of(
                                                    ctx4,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        'Delete failed: $e',
                                                      ),
                                                    ),
                                                  );
                                                }
                                              }
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
  }
}

String _fmtWhen(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
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
    final total = segments.fold<double>(0, (sum, s) => sum + s.value);
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

    // donut hole for readability
    final holePaint =
        Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.white;
    canvas.drawCircle(center, radius * 0.55, holePaint);
  }

  @override
  bool shouldRepaint(covariant _PiePainter oldDelegate) {
    if (oldDelegate.segments.length != segments.length) return true;
    for (var i = 0; i < segments.length; i++) {
      if (oldDelegate.segments[i].value != segments[i].value) return true;
    }
    return false;
  }
}

const _palette = <Color>[
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
