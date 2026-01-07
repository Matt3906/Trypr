import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> ensureNameCache(
  Map<String, String> cache,
  List<String> uids, {
  String? currentUidForFriendsFallback,
}) async {
  final missing =
      uids.where((u) => u.isNotEmpty && !cache.containsKey(u)).toList();

  Map<String, String> friendsNameByUid = const {};
  if (currentUidForFriendsFallback != null &&
      currentUidForFriendsFallback.isNotEmpty) {
    try {
      final meDoc =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(currentUidForFriendsFallback)
              .get();
      final meData = meDoc.data();
      final friendsRaw = (meData?['friends'] as List?) ?? const [];
      final tmp = <String, String>{};
      for (final entry in friendsRaw) {
        if (entry is Map) {
          final uid = (entry['uid'] ?? entry['id'] ?? '').toString();
          if (uid.isEmpty) continue;
          final name =
              (entry['displayName'] ?? entry['name'] ?? entry['email'] ?? '')
                  .toString()
                  .trim();
          if (name.isNotEmpty) tmp[uid] = name;
        }
      }
      friendsNameByUid = tmp;
    } catch (_) {
      friendsNameByUid = const {};
    }
  }

  for (final uid in missing) {
    try {
      // Preferred: public profile doc (readable by collaborators)
      final pub =
          await FirebaseFirestore.instance
              .collection('publicUsers')
              .doc(uid)
              .get();
      final pubData = pub.data();
      if (pubData != null) {
        final name =
            (pubData['displayName'] ??
                    pubData['name'] ??
                    pubData['email'] ??
                    uid)
                .toString();
        cache[uid] = name;
        continue;
      }

      // Safe fallback: resolve from *my* friends list (stored on my user doc)
      final friendName = friendsNameByUid[uid];
      if (friendName != null && friendName.trim().isNotEmpty) {
        cache[uid] = friendName;
        continue;
      }
    } catch (_) {
      // ignore and fall back
    }

    // Final fallback
    cache[uid] = uid;
  }
}
