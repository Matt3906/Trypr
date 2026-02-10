import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
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
        for (final field in formFields) {
          if (field is Map) {
            final id = field['id']?.toString() ?? '';
            if (id.isNotEmpty) {
              map[id] = {
                'label': field['label']?.toString() ?? 'Unlabeled Field',
                'type': field['type']?.toString() ?? 'text',
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

    rawResponses.forEach((key, value) {
      // Skip metadata fields
      if (key == 'submittedAt' ||
          key == 'submittedByUid' ||
          key == 'submittedByEmail' ||
          key == 'submittedByName' ||
          key == 'responses' ||
          key == 'formattedResponses') {
        return;
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
          label = 'Field ${formatted.length + 1}';
        }
      }

      formatted.add({'label': label, 'type': type, 'value': value});
    });

    return formatted;
  }

  /// Generate PDF for all responses
  Future<void> _exportToPdf() async {
    if (_allResponses.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No responses to export')));
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

  List<Map<String, dynamic>> _getFormattedResponses() {
    // First try the new formattedResponses array
    if (responseData['formattedResponses'] != null) {
      return (responseData['formattedResponses'] as List).cast<Map>().map((e) {
        return Map<String, dynamic>.from(e);
      }).toList();
    }

    // Fall back to parsing old format
    final formatted = <Map<String, dynamic>>[];

    // Check if there's a nested 'responses' object (old format)
    Map<dynamic, dynamic>? rawResponses;
    if (responseData['responses'] != null && responseData['responses'] is Map) {
      rawResponses = responseData['responses'] as Map<dynamic, dynamic>;
    } else {
      // If no nested responses, treat the entire responseData as responses
      rawResponses = responseData;
    }

    rawResponses.forEach((key, value) {
      final keyStr = key.toString();

      // Skip metadata fields
      if (keyStr == 'submittedAt' ||
          keyStr == 'submittedByUid' ||
          keyStr == 'submittedByEmail' ||
          keyStr == 'submittedByName' ||
          keyStr == 'responses' ||
          keyStr == 'formattedResponses') {
        return;
      }

      String label = keyStr;
      String type = 'text';

      // Try to get label from form fields map
      if (formFieldsMap != null && formFieldsMap!.containsKey(keyStr)) {
        label = formFieldsMap![keyStr]['label'] ?? keyStr;
        type = formFieldsMap![keyStr]['type'] ?? 'text';
      } else if (keyStr.startsWith('field_')) {
        // Make field IDs more readable by extracting a cleaner name
        final cleanLabel = keyStr
            .replaceFirst('field_', '')
            .replaceAll(RegExp(r'\d+'), '');
        label =
            cleanLabel.isNotEmpty
                ? cleanLabel
                : 'Response ${formatted.length + 1}';
      }

      formatted.add({'label': label, 'type': type, 'value': value});
    });

    return formatted;
  }

  @override
  Widget build(BuildContext context) {
    final submittedAt = responseData['submittedAt'] as Timestamp?;
    final submittedByName = responseData['submittedByName']?.toString();
    final submittedByEmail = responseData['submittedByEmail']?.toString();
    final formattedResponses = _getFormattedResponses();

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.all(16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
          submittedAt != null
              ? DateFormat('MMM dd, yyyy • h:mm a').format(submittedAt.toDate())
              : 'Date unknown',
          style: TextStyle(color: Colors.grey[600], fontSize: 13),
        ),
        children: [
          const Divider(),
          const SizedBox(height: 8),

          // User info
          if (submittedByEmail != null) ...[
            _InfoRow(
              icon: Icons.email,
              label: 'Email',
              value: submittedByEmail,
            ),
            const SizedBox(height: 12),
          ],

          // Form responses
          if (formattedResponses.isNotEmpty) ...[
            const Text(
              'Form Responses',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            ...formattedResponses.map((response) {
              final label = response['label']?.toString() ?? 'Field';
              final value = response['value'];
              final type = response['type']?.toString() ?? 'text';
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ResponseField(label: label, value: value, type: type),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Colors.grey[600]),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(fontSize: 14)),
            ],
          ),
        ),
      ],
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isEmpty ? Colors.grey[100] : Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
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
              fontWeight: FontWeight.w600,
              color: isEmpty ? Colors.grey[600] : const Color(0xFF00695C),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            displayValue,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: isEmpty ? Colors.grey[500] : Colors.black87,
              fontStyle: isEmpty ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ],
      ),
    );
  }
}
