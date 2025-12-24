import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:trypr/services/name_lookup.dart';

class TripChatDialog {
  static Future<void> show({
    required BuildContext context,
    required DocumentReference<Map<String, dynamic>> tripRef,
    required User me,
    String title = 'Trip chat',
    bool allowImageUrl = false,
  }) async {
    final msgCtl = TextEditingController();
    final imgCtl = TextEditingController();
    final nameCache = <String, String>{};
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          final dialogHeight =
              (MediaQuery.sizeOf(ctx).height * 0.75)
                  .clamp(360.0, 620.0)
                  .toDouble();

          return AlertDialog(
            title: Text(title),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SizedBox(
                width: double.maxFinite,
                height: dialogHeight,
                child: Column(
                  children: [
                    Expanded(
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream:
                            tripRef
                                .collection('messages')
                                .orderBy('createdAt', descending: true)
                                .snapshots(),
                        builder: (ctx2, snap) {
                          if (!snap.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }

                          final docs = snap.data!.docs;
                          if (docs.isEmpty) {
                            return const Center(child: Text('No messages yet'));
                          }

                          final senderUids = <String>{};
                          for (final d in docs) {
                            final uid =
                                (d.data()['senderUid'] ?? '').toString();
                            if (uid.isNotEmpty) senderUids.add(uid);
                          }

                          return FutureBuilder<void>(
                            future: ensureNameCache(
                              nameCache,
                              senderUids.toList(),
                              currentUidForFriendsFallback: me.uid,
                            ),
                            builder: (ctxN, _) {
                              return ListView.builder(
                                reverse: true,
                                itemCount: docs.length,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 8,
                                ),
                                itemBuilder: (ctx3, i) {
                                  final d = docs[i];
                                  final data = d.data();
                                  final senderUid =
                                      (data['senderUid'] ?? '').toString();
                                  final senderName =
                                      (data['senderName'] ?? '').toString();
                                  final text = (data['text'] ?? '').toString();
                                  final imageUrl =
                                      (data['imageUrl'] ?? '').toString();
                                  final ts = data['createdAt'];

                                  final isMe = senderUid == me.uid;
                                  final displayName =
                                      isMe
                                          ? 'You'
                                          : (nameCache[senderUid] ??
                                              (senderName.isNotEmpty
                                                  ? senderName
                                                  : senderUid));

                                  DateTime? createdAt;
                                  if (ts is Timestamp) {
                                    createdAt = ts.toDate();
                                  }

                                  return _MessageBubble(
                                    isMe: isMe,
                                    name: displayName,
                                    text: text,
                                    imageUrl: imageUrl,
                                    createdAt: createdAt,
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: msgCtl,
                            minLines: 1,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              hintText: 'Message',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Send',
                          onPressed: () async {
                            final t = msgCtl.text.trim();
                            final img = imgCtl.text.trim();
                            if (t.isEmpty && (!allowImageUrl || img.isEmpty)) {
                              return;
                            }

                            try {
                              await ensureNameCache(
                                nameCache,
                                [me.uid],
                                currentUidForFriendsFallback: me.uid,
                              );
                              final senderName =
                                  nameCache[me.uid] ?? (me.displayName ?? '');
                              await tripRef.collection('messages').add({
                                'senderUid': me.uid,
                                'senderName': senderName,
                                'text': t,
                                if (allowImageUrl)
                                  'imageUrl':
                                      img.isNotEmpty
                                          ? img
                                          : FieldValue.delete(),
                                'createdAt': FieldValue.serverTimestamp(),
                              });
                              msgCtl.clear();
                              imgCtl.clear();
                            } catch (e) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(content: Text('Send failed: $e')),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.send),
                        ),
                      ],
                    ),
                    if (allowImageUrl) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: imgCtl,
                        decoration: const InputDecoration(
                          hintText: 'Image URL (optional)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    } finally {
      msgCtl.dispose();
      imgCtl.dispose();
    }
  }
}

class _MessageBubble extends StatelessWidget {
  final bool isMe;
  final String name;
  final String text;
  final String imageUrl;
  final DateTime? createdAt;

  const _MessageBubble({
    required this.isMe,
    required this.name,
    required this.text,
    required this.imageUrl,
    required this.createdAt,
  });

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _formatTime(DateTime dt) {
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour12:${_two(dt.minute)} $ampm';
  }

  static String _formatDate(DateTime dt) => '${dt.month}/${dt.day}/${dt.year}';

  @override
  Widget build(BuildContext context) {
    final bubbleColor =
        isMe ? Theme.of(context).colorScheme.primary : Colors.grey.shade200;
    final textColor = isMe ? Colors.white : Colors.black87;

    final ts = createdAt;
    final tsLabel =
        ts == null
            ? ''
            : (() {
              final now = DateTime.now();
              final sameDay =
                  ts.year == now.year &&
                  ts.month == now.month &&
                  ts.day == now.day;
              return sameDay
                  ? _formatTime(ts)
                  : '${_formatDate(ts)}  ${_formatTime(ts)}';
            })();

    final maxBubbleWidth =
        MediaQuery.of(context).size.width >= 700 ? 420.0 : 320.0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxBubbleWidth),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(14),
                topRight: const Radius.circular(14),
                bottomLeft: Radius.circular(isMe ? 14 : 4),
                bottomRight: Radius.circular(isMe ? 4 : 14),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Column(
                crossAxisAlignment:
                    isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: isMe ? Colors.white70 : Colors.black54,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (text.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      text,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: textColor),
                    ),
                  ],
                  if (imageUrl.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        imageUrl,
                        width: 240,
                        fit: BoxFit.cover,
                        errorBuilder:
                            (_, __, ___) => Text(
                              'Image failed to load',
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(color: textColor),
                            ),
                      ),
                    ),
                  ],
                  if (tsLabel.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      tsLabel,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: isMe ? Colors.white70 : Colors.black45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
