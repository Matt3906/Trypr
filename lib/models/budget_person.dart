class BudgetPerson {
  final String id;
  final String name;
  final String? uid;

  const BudgetPerson({required this.id, required this.name, this.uid});

  bool get isLinkedUser => uid != null && uid!.trim().isNotEmpty;

  factory BudgetPerson.fromMap(Map<String, dynamic> data) {
    final rawUid = (data['uid'] ?? data['linkedUid'] ?? '').toString().trim();
    final rawName =
        (data['name'] ?? data['label'] ?? data['title'] ?? '')
            .toString()
            .trim();
    final rawId = (data['id'] ?? '').toString().trim();
    final resolvedId =
        rawId.isNotEmpty
            ? rawId
            : (rawUid.isNotEmpty ? rawUid : BudgetPerson.newCustomId());

    return BudgetPerson(
      id: resolvedId,
      name:
          rawName.isNotEmpty
              ? rawName
              : (rawUid.isNotEmpty ? rawUid : 'Person'),
      uid: rawUid.isEmpty ? null : rawUid,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      if (uid != null && uid!.trim().isNotEmpty) 'uid': uid,
    };
  }

  static BudgetPerson custom(String name, {String? id}) {
    final trimmed = name.trim();
    return BudgetPerson(
      id: (id ?? '').trim().isNotEmpty ? id!.trim() : newCustomId(),
      name: trimmed.isNotEmpty ? trimmed : 'Person',
    );
  }

  static String newCustomId() =>
      'person_${DateTime.now().microsecondsSinceEpoch}';
}

List<BudgetPerson> parseBudgetPeople(dynamic raw) {
  if (raw is! List) return const <BudgetPerson>[];
  final seenIds = <String>{};
  final people = <BudgetPerson>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final person = BudgetPerson.fromMap(Map<String, dynamic>.from(item));
    if (person.id.trim().isEmpty || !seenIds.add(person.id)) continue;
    people.add(person);
  }
  return people;
}

List<Map<String, dynamic>> encodeBudgetPeople(Iterable<BudgetPerson> people) {
  final seenIds = <String>{};
  final out = <Map<String, dynamic>>[];
  for (final person in people) {
    final id = person.id.trim();
    final name = person.name.trim();
    if (id.isEmpty || name.isEmpty || !seenIds.add(id)) continue;
    out.add(
      BudgetPerson(
        id: id,
        name: name,
        uid: person.uid?.trim().isNotEmpty == true ? person.uid!.trim() : null,
      ).toMap(),
    );
  }
  return out;
}

List<BudgetPerson> mergeBudgetPeople({
  required Iterable<String> participantUids,
  required Map<String, String> nameCache,
  Iterable<BudgetPerson> customPeople = const <BudgetPerson>[],
}) {
  final merged = <BudgetPerson>[];
  final seenIds = <String>{};

  for (final uid in participantUids) {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty || !seenIds.add(trimmedUid)) continue;
    merged.add(
      BudgetPerson(
        id: trimmedUid,
        name: (nameCache[trimmedUid] ?? trimmedUid).trim(),
        uid: trimmedUid,
      ),
    );
  }

  for (final person in customPeople) {
    if (person.id.trim().isEmpty || !seenIds.add(person.id)) continue;
    merged.add(person);
  }

  return merged;
}

BudgetPerson? budgetPersonById(Iterable<BudgetPerson> people, String? id) {
  final trimmedId = (id ?? '').trim();
  if (trimmedId.isEmpty) return null;
  for (final person in people) {
    if (person.id == trimmedId) return person;
  }
  return null;
}

String budgetPersonLabelForId({
  required Iterable<BudgetPerson> people,
  required String? id,
  String? fallbackName,
  String emptyLabel = 'Unassigned',
}) {
  final trimmedId = (id ?? '').trim();
  if (trimmedId.isEmpty) return emptyLabel;
  final person = budgetPersonById(people, trimmedId);
  if (person != null && person.name.trim().isNotEmpty) {
    return person.name.trim();
  }
  final fallback = (fallbackName ?? '').trim();
  return fallback.isNotEmpty ? fallback : trimmedId;
}
