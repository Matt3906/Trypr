import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Screen to view form responses for an unlisted page
class UnlistedPageResponsesScreen extends StatefulWidget {
  final String pageSlug;
  final String pageTitle;

  const UnlistedPageResponsesScreen({
    super.key,
    required this.pageSlug,
    required this.pageTitle,
  });

  @override
  State<UnlistedPageResponsesScreen> createState() =>
      _UnlistedPageResponsesScreenState();
}

class _UnlistedPageResponsesScreenState
    extends State<UnlistedPageResponsesScreen> {
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _allResponses = [];
  Map<String, dynamic>? _formFieldsMap; // To map field IDs to labels

  @override
  void initState() {
    super.initState();
    _loadFormFields();
  }

  /// Load form field definitions to map IDs to labels for old responses
  Future<void> _loadFormFields() async {
    try {
      final doc =
          await FirebaseFirestore.instance
              .collection('unlistedPages')
              .doc(widget.pageSlug)
              .get();

      if (doc.exists) {
        final formFields = doc.data()?['formFields'] as List<dynamic>? ?? [];
        final map = <String, dynamic>{};
        for (var i = 0; i < formFields.length; i++) {
          final field = formFields[i];
          if (field is Map) {
            final id = field['id']?.toString() ?? '';
            if (id.isNotEmpty) {
              map[id] = {
                'label': field['label']?.toString() ?? 'Unlabeled Field',
                'type': field['type']?.toString() ?? 'text',
                'order': i,
              };
            }
          }
        }
        if (mounted) {
          setState(() {
            _formFieldsMap = map;
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading form fields: $e');
    }
  }

  /// Convert old-format responses to formatted responses using field definitions
  List<Map<String, dynamic>> _convertOldResponses(
    Map<String, dynamic> rawResponses,
  ) {
    final formatted = <Map<String, dynamic>>[];

    final entries =
        rawResponses.entries.where((entry) {
          final key = entry.key;
          return key != 'submittedAt' &&
              key != 'submittedByUid' &&
              key != 'submittedByEmail' &&
              key != 'submittedByName' &&
              key != 'responses' &&
              key != 'formattedResponses';
        }).toList();

    entries.sort((a, b) {
      final orderA =
          (_formFieldsMap?[a.key]?['order'] as num?)?.toInt() ?? (1 << 30);
      final orderB =
          (_formFieldsMap?[b.key]?['order'] as num?)?.toInt() ?? (1 << 30);
      if (orderA != orderB) return orderA.compareTo(orderB);
      return a.key.compareTo(b.key);
    });

    for (var i = 0; i < entries.length; i++) {
      final key = entries[i].key;
      final value = entries[i].value;
      // Skip metadata fields
      if (key == 'submittedAt' ||
          key == 'submittedByUid' ||
          key == 'submittedByEmail' ||
          key == 'submittedByName' ||
          key == 'responses' ||
          key == 'formattedResponses') {
        continue;
      }

      String label = key;
      String type = 'text';

      // Try to get label from form fields map
      if (_formFieldsMap != null && _formFieldsMap!.containsKey(key)) {
        label = _formFieldsMap![key]['label'] ?? key;
        type = _formFieldsMap![key]['type'] ?? 'text';
      } else {
        // Clean up field_xxx format
        if (key.startsWith('field_')) {
          final cleaned =
              key
                  .replaceFirst('field_', '')
                  .replaceAll(RegExp(r'[_\-]+'), ' ')
                  .replaceAll(RegExp(r'\d+$'), '')
                  .trim();
          label = cleaned.isEmpty ? 'Field ${i + 1}' : cleaned;
        }
      }

      formatted.add({'label': label, 'type': type, 'value': value});
    }

    return formatted;
  }

  /// Generate PDF for all responses
  Future<void> _exportToPdf() async {
    if (_allResponses.isEmpty) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('No responses to export')),
      );
      return;
    }

    final pdf = pw.Document();

    // Title page
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Form Responses Report',
                style: pw.TextStyle(
                  fontSize: 24,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                widget.pageTitle,
                style: const pw.TextStyle(fontSize: 18),
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                'Generated: ${DateFormat('MMMM dd, yyyy • h:mm a').format(DateTime.now())}',
                style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey),
              ),
              pw.Text(
                'Total Responses: ${_allResponses.length}',
                style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey),
              ),
              pw.Divider(thickness: 2),
              pw.SizedBox(height: 16),
            ],
          );
        },
      ),
    );

    // Add each response
    for (int i = 0; i < _allResponses.length; i++) {
      final data = _allResponses[i].data();
      final submittedAt = data['submittedAt'] as Timestamp?;
      final submittedByName = data['submittedByName']?.toString();
      final submittedByEmail = data['submittedByEmail']?.toString();

      // Get formatted responses or convert old format
      List<Map<String, dynamic>> formattedResponses;
      if (data['formattedResponses'] != null) {
        formattedResponses =
            (data['formattedResponses'] as List).cast<Map>().map((e) {
              return Map<String, dynamic>.from(e);
            }).toList();
      } else if (data['responses'] != null) {
        formattedResponses = _convertOldResponses(
          Map<String, dynamic>.from(data['responses'] as Map),
        );
      } else {
        formattedResponses = _convertOldResponses(data);
      }

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                // Response header
                pw.Container(
                  padding: const pw.EdgeInsets.all(12),
                  decoration: pw.BoxDecoration(
                    color: PdfColors.teal50,
                    borderRadius: pw.BorderRadius.circular(8),
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'Response #${i + 1}',
                        style: pw.TextStyle(
                          fontSize: 16,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Text(
                        submittedAt != null
                            ? DateFormat(
                              'MMM dd, yyyy • h:mm a',
                            ).format(submittedAt.toDate())
                            : 'Date unknown',
                        style: const pw.TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 8),

                // Submitter info
                if (submittedByName != null || submittedByEmail != null)
                  pw.Text(
                    'Submitted by: ${submittedByName ?? submittedByEmail ?? 'Anonymous'}',
                    style: const pw.TextStyle(fontSize: 12),
                  ),
                if (submittedByEmail != null && submittedByName != null)
                  pw.Text(
                    'Email: $submittedByEmail',
                    style: const pw.TextStyle(
                      fontSize: 11,
                      color: PdfColors.grey,
                    ),
                  ),

                pw.SizedBox(height: 12),
                pw.Divider(),
                pw.SizedBox(height: 12),

                // Form fields
                ...formattedResponses.map((response) {
                  final label = response['label']?.toString() ?? 'Field';
                  final value = _formatValue(response['value']);

                  return pw.Container(
                    margin: const pw.EdgeInsets.only(bottom: 12),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          label,
                          style: pw.TextStyle(
                            fontSize: 11,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColors.teal800,
                          ),
                        ),
                        pw.SizedBox(height: 4),
                        pw.Container(
                          padding: const pw.EdgeInsets.all(8),
                          width: double.infinity,
                          decoration: pw.BoxDecoration(
                            color: PdfColors.grey100,
                            borderRadius: pw.BorderRadius.circular(4),
                          ),
                          child: pw.Text(
                            value.isEmpty ? '(not answered)' : value,
                            style: pw.TextStyle(
                              fontSize: 12,
                              fontStyle:
                                  value.isEmpty
                                      ? pw.FontStyle.italic
                                      : pw.FontStyle.normal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            );
          },
        ),
      );
    }

    // Show print/save dialog
    await Printing.layoutPdf(
      onLayout: (format) async => pdf.save(),
      name: '${widget.pageTitle.replaceAll(RegExp(r'[^\w\s]'), '_')}_responses',
    );
  }

  String _formatValue(dynamic value) {
    if (value == null) return '';

    if (value is List) {
      return value.join(', ');
    } else if (value is Map) {
      final parts = <String>[];
      if (value['street']?.toString().isNotEmpty == true) {
        parts.add(value['street'].toString());
      }
      if (value['street2']?.toString().isNotEmpty == true) {
        parts.add(value['street2'].toString());
      }
      if (value['city']?.toString().isNotEmpty == true ||
          value['province']?.toString().isNotEmpty == true ||
          value['postal']?.toString().isNotEmpty == true) {
        parts.add(
          '${value['city'] ?? ''}, ${value['province'] ?? ''} ${value['postal'] ?? ''}'
              .trim(),
        );
      }
      if (parts.isNotEmpty) return parts.join('\n');

      // Generic map formatting
      return value.entries.map((e) => '${e.key}: ${e.value}').join(', ');
    }

    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Responses: ${widget.pageTitle}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'Export to PDF',
            onPressed: _exportToPdf,
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream:
            FirebaseFirestore.instance
                .collection('unlistedPages')
                .doc(widget.pageSlug)
                .collection('responses')
                .orderBy('submittedAt', descending: true)
                .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          _allResponses = snapshot.data!.docs;

          if (_allResponses.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.inbox, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No responses yet',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return Column(
            children: [
              // Export button bar
              Container(
                padding: const EdgeInsets.all(16),
                color: Colors.grey[100],
                child: Row(
                  children: [
                    Text(
                      '${_allResponses.length} response${_allResponses.length == 1 ? '' : 's'}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      onPressed: _exportToPdf,
                      icon: const Icon(Icons.picture_as_pdf, size: 18),
                      label: const Text('Export All to PDF'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00B894),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              // Responses list
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _allResponses.length,
                  itemBuilder: (context, index) {
                    final doc = _allResponses[index];
                    final data = doc.data();
                    return _ResponseCard(
                      responseData: data,
                      responseId: doc.id,
                      index: index + 1,
                      formFieldsMap: _formFieldsMap,
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ResponseCard extends StatelessWidget {
  final Map<String, dynamic> responseData;
  final String responseId;
  final int index;
  final Map<String, dynamic>? formFieldsMap;

  const _ResponseCard({
    required this.responseData,
    required this.responseId,
    required this.index,
    this.formFieldsMap,
  });

  static const Set<String> _metaKeys = {
    'submittedAt',
    'submittedByUid',
    'submittedByEmail',
    'submittedByName',
    'responses',
    'formattedResponses',
  };

  bool _looksLikeFieldId(String value) {
    final v = value.trim().toLowerCase();
    return v.startsWith('field_') || v.startsWith('fld_');
  }

  int _fieldOrder(String? fieldId) {
    if (fieldId == null || fieldId.isEmpty || formFieldsMap == null) {
      return 1 << 30;
    }
    final order = formFieldsMap![fieldId]?['order'];
    if (order is int) return order;
    if (order is num) return order.toInt();
    return 1 << 30;
  }

  String _cleanFieldId(String value) {
    var out = value;
    if (out.startsWith('field_')) out = out.substring('field_'.length);
    out = out.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
    out = out.replaceAll(RegExp(r'\d+$'), '').trim();
    if (out.isEmpty) return '';
    return out
        .split(' ')
        .where((p) => p.isNotEmpty)
        .map((p) => '${p[0].toUpperCase()}${p.substring(1)}')
        .join(' ');
  }

  String _resolveLabel({
    required String? fieldId,
    required String? fallbackLabel,
    required int fallbackIndex,
  }) {
    if (fieldId != null && fieldId.isNotEmpty && formFieldsMap != null) {
      final mapped = formFieldsMap![fieldId]?['label']?.toString();
      if (mapped != null && mapped.trim().isNotEmpty) return mapped.trim();
    }

    final label = (fallbackLabel ?? '').trim();
    if (label.isNotEmpty) {
      if (formFieldsMap != null && formFieldsMap!.containsKey(label)) {
        final mapped = formFieldsMap![label]?['label']?.toString();
        if (mapped != null && mapped.trim().isNotEmpty) return mapped.trim();
      }
      if (!_looksLikeFieldId(label)) return label;
      final cleaned = _cleanFieldId(label);
      if (cleaned.isNotEmpty) return cleaned;
    }

    if (fieldId != null && fieldId.isNotEmpty) {
      final cleaned = _cleanFieldId(fieldId);
      if (cleaned.isNotEmpty) return cleaned;
    }

    return 'Field ${fallbackIndex + 1}';
  }

  String _resolveType({required String? fieldId, required String? fallback}) {
    if (fieldId != null && fieldId.isNotEmpty && formFieldsMap != null) {
      final mapped = formFieldsMap![fieldId]?['type']?.toString();
      if (mapped != null && mapped.trim().isNotEmpty) return mapped.trim();
    }
    final type = (fallback ?? '').trim();
    return type.isEmpty ? 'text' : type;
  }

  List<Map<String, dynamic>> _getFormattedResponses() {
    final rows = <Map<String, dynamic>>[];

    final formattedResponsesRaw = responseData['formattedResponses'];
    if (formattedResponsesRaw is List) {
      for (var i = 0; i < formattedResponsesRaw.length; i++) {
        final item = formattedResponsesRaw[i];
        if (item is! Map) continue;
        final row = Map<String, dynamic>.from(item.cast<dynamic, dynamic>());
        var fieldId =
            row['fieldId']?.toString() ??
            row['id']?.toString() ??
            row['key']?.toString();
        final rawLabel = row['label']?.toString();
        if ((fieldId == null || fieldId.isEmpty) &&
            rawLabel != null &&
            (formFieldsMap?.containsKey(rawLabel) ?? false)) {
          fieldId = rawLabel;
        }
        rows.add({
          'label': _resolveLabel(
            fieldId: fieldId,
            fallbackLabel: rawLabel,
            fallbackIndex: i,
          ),
          'type': _resolveType(
            fieldId: fieldId,
            fallback: row['type']?.toString(),
          ),
          'value': row['value'],
          '_order': _fieldOrder(fieldId),
          '_fallback': i,
        });
      }
    }

    if (rows.isEmpty) {
      Map<dynamic, dynamic> rawResponses;
      if (responseData['responses'] is Map) {
        rawResponses = responseData['responses'] as Map<dynamic, dynamic>;
      } else {
        rawResponses = responseData;
      }

      final entries =
          rawResponses.entries
              .where((e) => !_metaKeys.contains(e.key.toString()))
              .toList();

      for (var i = 0; i < entries.length; i++) {
        final keyStr = entries[i].key.toString();
        rows.add({
          'label': _resolveLabel(
            fieldId: keyStr,
            fallbackLabel: keyStr,
            fallbackIndex: i,
          ),
          'type': _resolveType(fieldId: keyStr, fallback: null),
          'value': entries[i].value,
          '_order': _fieldOrder(keyStr),
          '_fallback': i,
        });
      }
    }

    rows.sort((a, b) {
      final orderA = (a['_order'] as int?) ?? (1 << 30);
      final orderB = (b['_order'] as int?) ?? (1 << 30);
      if (orderA != orderB) return orderA.compareTo(orderB);
      final fallbackA = (a['_fallback'] as int?) ?? 0;
      final fallbackB = (b['_fallback'] as int?) ?? 0;
      return fallbackA.compareTo(fallbackB);
    });

    return rows
        .map(
          (row) => {
            'label': row['label'],
            'type': row['type'],
            'value': row['value'],
          },
        )
        .toList();
  }

  bool _isAnswered(dynamic value) {
    if (value == null) return false;
    if (value is String) return value.trim().isNotEmpty;
    if (value is List) return value.isNotEmpty;
    if (value is Map) {
      return value.values.any(
        (v) => v != null && v.toString().trim().isNotEmpty,
      );
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final submittedAt = responseData['submittedAt'] as Timestamp?;
    final submittedByName = responseData['submittedByName']?.toString();
    final submittedByEmail = responseData['submittedByEmail']?.toString();
    final formattedResponses = _getFormattedResponses();
    final answeredCount =
        formattedResponses.where((r) => _isAnswered(r['value'])).length;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        childrenPadding: EdgeInsets.zero,
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF00B894),
          child: Text(
            '$index',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          submittedByName ?? submittedByEmail ?? 'Anonymous',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${submittedAt != null ? DateFormat('MMM dd, yyyy • h:mm a').format(submittedAt.toDate()) : 'Date unknown'} • $answeredCount/${formattedResponses.length} answered',
          style: TextStyle(color: Colors.grey[600], fontSize: 13),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(height: 16),

                if (submittedByEmail != null) ...[
                  _InfoRow(
                    icon: Icons.email_outlined,
                    label: 'Email',
                    value: submittedByEmail,
                  ),
                  const SizedBox(height: 14),
                ],

                if (formattedResponses.isNotEmpty) ...[
                  const Text(
                    'Form Responses',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  ...formattedResponses.map((response) {
                    final label = response['label']?.toString() ?? 'Field';
                    final value = response['value'];
                    final type = response['type']?.toString() ?? 'text';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SizedBox(
                        width: double.infinity,
                        child: _ResponseField(
                          label: label,
                          value: value,
                          type: type,
                        ),
                      ),
                    );
                  }),
                ] else ...[
                  const Text(
                    'No form data available',
                    style: TextStyle(
                      fontSize: 14,
                      fontStyle: FontStyle.italic,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: Colors.grey[700]),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(value, style: const TextStyle(fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResponseField extends StatelessWidget {
  final String label;
  final dynamic value;
  final String type;

  const _ResponseField({
    required this.label,
    required this.value,
    required this.type,
  });

  @override
  Widget build(BuildContext context) {
    String displayValue;

    if (value == null) {
      displayValue = '(not answered)';
    } else if (value is List) {
      // Handle checkbox arrays
      final list = value as List;
      if (list.isEmpty) {
        displayValue = '(none selected)';
      } else {
        displayValue = list.map((e) => e.toString()).join(', ');
      }
    } else if (value is Map) {
      // Format address and other composite fields
      final map = value as Map;
      final parts = <String>[];

      // Check if it's an address object
      if (map.containsKey('street') || map.containsKey('city')) {
        if (map['street']?.toString().isNotEmpty == true) {
          parts.add(map['street'].toString());
        }
        if (map['street2']?.toString().isNotEmpty == true) {
          parts.add(map['street2'].toString());
        }
        final cityLine = <String>[];
        if (map['city']?.toString().isNotEmpty == true) {
          cityLine.add(map['city'].toString());
        }
        if (map['province']?.toString().isNotEmpty == true) {
          cityLine.add(map['province'].toString());
        }
        if (map['postal']?.toString().isNotEmpty == true) {
          cityLine.add(map['postal'].toString());
        }
        if (cityLine.isNotEmpty) {
          parts.add(cityLine.join(', '));
        }
        displayValue = parts.isNotEmpty ? parts.join('\n') : '(not provided)';
      } else {
        // Generic map formatting - clean it up
        final entries =
            map.entries
                .where((e) => e.value?.toString().isNotEmpty == true)
                .map((e) {
                  final key = e.key.toString();
                  final val = e.value.toString();
                  // Capitalize first letter of key
                  final cleanKey = key[0].toUpperCase() + key.substring(1);
                  return '$cleanKey: $val';
                })
                .toList();
        displayValue =
            entries.isNotEmpty ? entries.join('\n') : '(not provided)';
      }
    } else if (value is bool) {
      displayValue = value ? 'Yes' : 'No';
    } else if (value is Timestamp) {
      displayValue = DateFormat('MMM dd, yyyy • h:mm a').format(value.toDate());
    } else {
      final strValue = value.toString();
      if (strValue.trim().isEmpty) {
        displayValue = '(not answered)';
      } else {
        displayValue = strValue;
      }
    }

    final bool isEmpty =
        displayValue == '(not answered)' ||
        displayValue == '(not provided)' ||
        displayValue == '(none selected)';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isEmpty ? Colors.grey[100] : Colors.grey[50],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isEmpty ? Colors.grey.shade300 : Colors.grey.shade200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: isEmpty ? Colors.grey[600] : const Color(0xFF00695C),
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            displayValue,
            style: TextStyle(
              fontSize: 14,
              height: 1.45,
              color: isEmpty ? Colors.grey[500] : Colors.black87,
              fontStyle: isEmpty ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ],
      ),
    );
  }
}
