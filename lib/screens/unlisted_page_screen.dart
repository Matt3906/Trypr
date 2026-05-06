import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:trypr/services/pick_file_data_url.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:trypr/widgets/top_taskbar.dart';

/// Public view for unlisted pages - accessible via direct link
class UnlistedPageScreen extends StatefulWidget {
  final String pageSlug;

  const UnlistedPageScreen({super.key, required this.pageSlug});

  static Route<void> route({required String pageSlug}) {
    return MaterialPageRoute<void>(
      builder: (_) => UnlistedPageScreen(pageSlug: pageSlug),
    );
  }

  @override
  State<UnlistedPageScreen> createState() => _UnlistedPageScreenState();
}

class _UnlistedPageScreenState extends State<UnlistedPageScreen> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, dynamic> _formValues = {}; // For non-text fields
  final Set<String> _uploadingFileFieldIds = <String>{};
  bool _submitting = false;
  bool _submitted = false;
  String? _submissionError;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  ({Uint8List bytes, String contentType})? _decodeDataUrl(String dataUrl) {
    final raw = dataUrl.trim();
    if (!raw.startsWith('data:')) return null;
    final comma = raw.indexOf(',');
    if (comma <= 0) return null;

    final header = raw.substring(0, comma);
    final payload = raw.substring(comma + 1);

    String contentType = 'application/octet-stream';
    if (header.startsWith('data:')) {
      final meta = header.substring(5);
      final parts = meta.split(';');
      if (parts.isNotEmpty && parts.first.trim().isNotEmpty) {
        contentType = parts.first.trim();
      }
    }

    try {
      return (bytes: base64Decode(payload), contentType: contentType);
    } catch (_) {
      return null;
    }
  }

  String _sanitizeFileName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 'file.bin';
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  String _normalizeMarkdown(String raw) {
    return raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  }

  Future<Map<String, dynamic>?> _pickAndUploadFormFile({
    required String fieldId,
    required String fieldLabel,
  }) async {
    if (!kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(content: Text('File upload is currently web-only.')),
        );
      }
      return null;
    }

    final picked = await pickFileDataUrl(
      accept: '.pdf,.png,.jpg,.jpeg,.webp,.txt,.doc,.docx,.xls,.xlsx,.csv,.rtf',
    );
    if (picked == null) return null;

    final decoded = _decodeDataUrl(picked.dataUrl);
    if (decoded == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          const SnackBar(content: Text('Unsupported file selected.')),
        );
      }
      return null;
    }

    final safeName = _sanitizeFileName(picked.fileName);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final storagePath =
        'unlistedFormUploads/${widget.pageSlug}/$fieldId/${ts}_$safeName';
    final ref = FirebaseStorage.instance.ref(storagePath);

    final task = await ref.putData(
      decoded.bytes,
      SettableMetadata(
        contentType: decoded.contentType,
        customMetadata: {
          'pageSlug': widget.pageSlug,
          'fieldId': fieldId,
          'fieldLabel': fieldLabel,
          'originalName': picked.fileName,
        },
      ),
    );
    final url = await task.ref.getDownloadURL();

    return {
      'fileName': picked.fileName,
      'url': url,
      'contentType': decoded.contentType,
      'sizeBytes': decoded.bytes.length,
      'storagePath': storagePath,
      'uploadedAt': DateTime.now().toIso8601String(),
    };
  }

  Future<void> _submitForm(Map<String, dynamic> pageData) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _submitting = true;
      _submissionError = null;
    });

    try {
      final formFields = (pageData['formFields'] as List<dynamic>?) ?? [];
      final Map<String, dynamic> responses = {};
      final List<Map<String, dynamic>> formattedResponses = [];

      for (final field in formFields) {
        if (field is! Map) continue;
        final fieldId = field['id']?.toString() ?? '';
        final fieldLabel = field['label']?.toString() ?? 'Unlabeled Field';
        final fieldType = field['type']?.toString() ?? 'text';
        if (fieldId.isEmpty) continue;

        // Get value based on field type
        dynamic value;
        if (fieldType == 'dropdown' ||
            fieldType == 'radio' ||
            fieldType == 'date' ||
            fieldType == 'checkbox') {
          value = _formValues[fieldId] ?? '';
        } else if (fieldType == 'file') {
          final fileData = _formValues[fieldId];
          if (fileData is Map) {
            value = Map<String, dynamic>.from(
              fileData.cast<dynamic, dynamic>(),
            );
          } else if (fileData is String && fileData.trim().isNotEmpty) {
            value = {'fileName': fileData.trim(), 'url': fileData.trim()};
          } else {
            value = <String, dynamic>{};
          }
        } else if (fieldType == 'name') {
          final nameData = _formValues[fieldId] as Map?;
          value =
              '${nameData?['first'] ?? ''} ${nameData?['last'] ?? ''}'.trim();
        } else if (fieldType == 'address') {
          final addrData = _formValues[fieldId] as Map?;
          value = {
            'street': addrData?['street'] ?? '',
            'street2': addrData?['street2'] ?? '',
            'city': addrData?['city'] ?? '',
            'province': addrData?['province'] ?? '',
            'postal': addrData?['postal'] ?? '',
          };
        } else if (fieldType == 'signature') {
          value =
              _formValues[fieldId] != null &&
                      (_formValues[fieldId] as String).isNotEmpty
                  ? 'Signed'
                  : '';
        } else {
          value = _controllers[fieldId]?.text ?? '';
        }

        responses[fieldId] = value;

        // Create formatted version for easy reading
        formattedResponses.add({
          'label': fieldLabel,
          'type': fieldType,
          'value': value,
        });
      }

      final user = FirebaseAuth.instance.currentUser;

      await FirebaseFirestore.instance
          .collection('unlistedPages')
          .doc(widget.pageSlug)
          .collection('responses')
          .add({
            'responses': responses,
            'formattedResponses': formattedResponses, // Human-readable version
            'submittedAt': FieldValue.serverTimestamp(),
            'submittedByUid': user?.uid,
            'submittedByEmail': user?.email,
            'submittedByName': user?.displayName,
          });

      if (mounted) {
        setState(() {
          _submitted = true;
          _submitting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submissionError = e.toString();
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TopTaskbar(dockProgress: 1.0),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream:
            FirebaseFirestore.instance
                .collection('unlistedPages')
                .doc(widget.pageSlug)
                .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  Text(
                    'Error loading page',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    snapshot.error.toString(),
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ],
              ),
            );
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final doc = snapshot.data!;
          if (!doc.exists) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.link_off, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    'Page not found',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This link may have expired or been removed.',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Looking for: ${widget.pageSlug}',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                ],
              ),
            );
          }

          final data = doc.data()!;
          final title = data['title']?.toString() ?? 'Untitled Page';
          final description = data['description']?.toString() ?? '';
          final content = data['content']?.toString() ?? '';
          final normalizedDescription = _normalizeMarkdown(description);
          final normalizedContent = _normalizeMarkdown(content);
          final coverImage = data['coverImage']?.toString() ?? '';
          final formFields = (data['formFields'] as List<dynamic>?) ?? [];
          final formEnabled = data['formEnabled'] == true;
          final formTitle = data['formTitle']?.toString() ?? 'Sign Up';
          final formButtonText = data['formButtonText']?.toString() ?? 'Submit';
          final viewportWidth = MediaQuery.sizeOf(context).width;
          final heroHeight = (viewportWidth * 0.42).clamp(220.0, 420.0);
          final horizontalPadding = viewportWidth < 600 ? 16.0 : 24.0;
          final formPadding = viewportWidth < 600 ? 16.0 : 24.0;
          final heroTitleStyle =
              Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.white,
                shadows: const [Shadow(blurRadius: 10, color: Colors.black54)],
              ) ??
              const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                shadows: [Shadow(blurRadius: 10, color: Colors.black54)],
              );
          final pageTitleStyle =
              Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ) ??
              const TextStyle(fontSize: 32, fontWeight: FontWeight.bold);

          // Initialize controllers for form fields
          for (final field in formFields) {
            if (field is! Map) continue;
            final fieldId = field['id']?.toString() ?? '';
            if (fieldId.isNotEmpty && !_controllers.containsKey(fieldId)) {
              _controllers[fieldId] = TextEditingController();
            }
          }

          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Hero Section
                if (coverImage.isNotEmpty)
                  SizedBox(
                    height: heroHeight.toDouble(),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Image.network(
                            coverImage,
                            fit: BoxFit.cover,
                            semanticLabel: '$title cover image',
                            errorBuilder:
                                (_, __, ___) =>
                                    Container(color: Colors.grey[300]),
                          ),
                        ),
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.6),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: horizontalPadding,
                          right: horizontalPadding,
                          bottom: horizontalPadding,
                          child: Text(title, style: heroTitleStyle),
                        ),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: EdgeInsets.all(horizontalPadding + 8),
                    child: Text(title, style: pageTitleStyle),
                  ),

                // Content Section
                Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontalPadding,
                      vertical: 24,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 860),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (normalizedDescription.isNotEmpty) ...[
                            MarkdownBody(
                              data: normalizedDescription,
                              selectable: true,
                              styleSheet: MarkdownStyleSheet.fromTheme(
                                Theme.of(context),
                              ).copyWith(
                                p: TextStyle(
                                  fontSize: 18,
                                  color: Colors.grey[700],
                                  height: 1.5,
                                ),
                                h1: const TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w700,
                                ),
                                h2: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                ),
                                h3: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                          ],
                          if (normalizedContent.isNotEmpty) ...[
                            MarkdownBody(
                              data: normalizedContent,
                              selectable: true,
                              styleSheet: MarkdownStyleSheet.fromTheme(
                                Theme.of(context),
                              ).copyWith(
                                p: const TextStyle(fontSize: 16, height: 1.55),
                                h1: const TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w700,
                                ),
                                h2: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                ),
                                h3: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                                h4: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(height: 32),
                          ],

                          // Form Section
                          if (formEnabled && !_submitted) ...[
                            Card(
                              elevation: 2,
                              child: Padding(
                                padding: EdgeInsets.all(formPadding),
                                child: Form(
                                  key: _formKey,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        formTitle,
                                        style: const TextStyle(
                                          fontSize: 24,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      ...formFields.map((field) {
                                        if (field is! Map) {
                                          return const SizedBox.shrink();
                                        }
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 16,
                                          ),
                                          child: _buildFormField(
                                            field as Map<String, dynamic>,
                                          ),
                                        );
                                      }),
                                      const SizedBox(height: 24),
                                      if (_submissionError != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 16,
                                          ),
                                          child: Text(
                                            'Error: $_submissionError',
                                            style: const TextStyle(
                                              color: Colors.red,
                                            ),
                                          ),
                                        ),
                                      ElevatedButton(
                                        onPressed:
                                            _submitting
                                                ? null
                                                : () => _submitForm(data),
                                        style: ElevatedButton.styleFrom(
                                          minimumSize: const Size.fromHeight(
                                            52,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 16,
                                          ),
                                          backgroundColor: const Color(
                                            0xFF00B894,
                                          ),
                                          foregroundColor: Colors.white,
                                        ),
                                        child:
                                            _submitting
                                                ? const SizedBox(
                                                  height: 20,
                                                  width: 20,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    valueColor:
                                                        AlwaysStoppedAnimation<
                                                          Color
                                                        >(Colors.white),
                                                  ),
                                                )
                                                : Text(
                                                  formButtonText,
                                                  style: const TextStyle(
                                                    fontSize: 16,
                                                  ),
                                                ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],

                          // Success Message
                          if (_submitted)
                            Card(
                              elevation: 2,
                              color: Colors.green.shade50,
                              child: Padding(
                                padding: EdgeInsets.all(formPadding),
                                child: Column(
                                  children: [
                                    Icon(
                                      Icons.check_circle_outline,
                                      size: 64,
                                      color: Colors.green.shade700,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      'Thank You!',
                                      style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green.shade900,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Your submission has been received.',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: Colors.green.shade800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildFormField(Map<String, dynamic> field) {
    final fieldId = field['id']?.toString() ?? '';
    final label = field['label']?.toString() ?? 'Field';
    final type = field['type']?.toString() ?? 'text';
    final required = field['required'] == true;
    final options = (field['options'] as List<dynamic>?)?.cast<String>() ?? [];

    final controller = _controllers[fieldId];
    final decoration = InputDecoration(
      labelText: required ? '$label *' : label,
      border: const OutlineInputBorder(),
    );

    switch (type) {
      case 'email':
        return TextFormField(
          controller: controller,
          decoration: decoration,
          keyboardType: TextInputType.emailAddress,
          validator:
              required
                  ? (v) {
                    if (v?.trim().isEmpty ?? true) return 'Required';
                    final emailRegex = RegExp(
                      r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$',
                    );
                    if (!emailRegex.hasMatch(v!)) return 'Invalid email';
                    return null;
                  }
                  : null,
        );

      case 'phone':
        return TextFormField(
          controller: controller,
          decoration: decoration,
          keyboardType: TextInputType.phone,
          validator:
              required
                  ? (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null
                  : null,
        );

      case 'number':
        return TextFormField(
          controller: controller,
          decoration: decoration,
          keyboardType: TextInputType.number,
          validator:
              required
                  ? (v) {
                    if (v?.trim().isEmpty ?? true) return 'Required';
                    if (double.tryParse(v!) == null) return 'Invalid number';
                    return null;
                  }
                  : null,
        );

      case 'textarea':
        return TextFormField(
          controller: controller,
          decoration: decoration,
          maxLines: 4,
          validator:
              required
                  ? (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null
                  : null,
        );

      case 'dropdown':
        return DropdownButtonFormField<String>(
          initialValue: _formValues[fieldId] as String?,
          decoration: decoration,
          items:
              options
                  .map((opt) => DropdownMenuItem(value: opt, child: Text(opt)))
                  .toList(),
          onChanged: (val) => setState(() => _formValues[fieldId] = val),
          validator:
              required
                  ? (v) => v == null || v.isEmpty ? 'Required' : null
                  : null,
        );

      case 'radio':
        return FormField<String>(
          initialValue: _formValues[fieldId] as String?,
          validator:
              required
                  ? (v) => v == null || v.isEmpty ? 'Required' : null
                  : null,
          builder: (field) {
            return RadioGroup<String>(
              groupValue: _formValues[fieldId] as String?,
              onChanged: (val) {
                setState(() => _formValues[fieldId] = val);
                field.didChange(val);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    required ? '$label *' : label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  ...options.map((opt) {
                    return RadioListTile<String>(
                      title: Text(opt),
                      value: opt,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    );
                  }),
                  if (field.hasError)
                    Padding(
                      padding: const EdgeInsets.only(left: 12, top: 8),
                      child: Text(
                        field.errorText ?? '',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );

      case 'checkbox':
        return FormField<List<String>>(
          initialValue: (_formValues[fieldId] as List?)?.cast<String>() ?? [],
          validator:
              required
                  ? (v) => v == null || v.isEmpty ? 'Select at least one' : null
                  : null,
          builder: (field) {
            final selected =
                (_formValues[fieldId] as List?)?.cast<String>() ?? [];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  required ? '$label *' : label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                ...options.map((opt) {
                  return CheckboxListTile(
                    title: Text(opt),
                    value: selected.contains(opt),
                    onChanged: (checked) {
                      final newList = List<String>.from(selected);
                      if (checked == true) {
                        newList.add(opt);
                      } else {
                        newList.remove(opt);
                      }
                      setState(() => _formValues[fieldId] = newList);
                      field.didChange(newList);
                    },
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  );
                }),
                if (field.hasError)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 8),
                    child: Text(
                      field.errorText ?? '',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            );
          },
        );

      case 'date':
        return FormField<String>(
          initialValue: _formValues[fieldId] as String?,
          validator:
              required
                  ? (v) => v == null || v.isEmpty ? 'Required' : null
                  : null,
          builder: (field) {
            final dateStr = _formValues[fieldId] as String?;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  required ? '$label *' : label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now(),
                      firstDate: DateTime(1900),
                      lastDate: DateTime(2100),
                    );
                    if (date != null) {
                      final formatted =
                          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
                      setState(() => _formValues[fieldId] = formatted);
                      field.didChange(formatted);
                    }
                  },
                  icon: const Icon(Icons.calendar_today),
                  label: Text(dateStr ?? 'Select Date'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                    alignment: Alignment.centerLeft,
                  ),
                ),
                if (field.hasError)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 8),
                    child: Text(
                      field.errorText ?? '',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            );
          },
        );

      case 'file':
        return FormField<Map<String, dynamic>>(
          initialValue:
              _formValues[fieldId] is Map
                  ? Map<String, dynamic>.from(
                    (_formValues[fieldId] as Map).cast<dynamic, dynamic>(),
                  )
                  : null,
          validator:
              required
                  ? (v) {
                    final url = (v?['url'] ?? '').toString().trim();
                    return url.isEmpty ? 'Required' : null;
                  }
                  : null,
          builder: (field) {
            final current =
                _formValues[fieldId] is Map
                    ? Map<String, dynamic>.from(
                      (_formValues[fieldId] as Map).cast<dynamic, dynamic>(),
                    )
                    : <String, dynamic>{};
            final fileName = (current['fileName'] ?? '').toString();
            final hasFile = (current['url'] ?? '').toString().trim().isNotEmpty;
            final uploading = _uploadingFileFieldIds.contains(fieldId);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  required ? '$label *' : label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed:
                      uploading
                          ? null
                          : () async {
                            setState(() {
                              _uploadingFileFieldIds.add(fieldId);
                            });
                            try {
                              final uploaded = await _pickAndUploadFormFile(
                                fieldId: fieldId,
                                fieldLabel: label,
                              );
                              if (uploaded != null && mounted) {
                                setState(() => _formValues[fieldId] = uploaded);
                                field.didChange(uploaded);
                              }
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showTryprSnackBar(
                                SnackBar(
                                  content: Text('File upload failed: $e'),
                                ),
                              );
                            } finally {
                              if (mounted) {
                                setState(() {
                                  _uploadingFileFieldIds.remove(fieldId);
                                });
                              }
                            }
                          },
                  icon:
                      uploading
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(Icons.upload_file),
                  label: Text(
                    uploading
                        ? 'Uploading...'
                        : hasFile
                        ? fileName
                        : 'Choose File',
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                    alignment: Alignment.centerLeft,
                  ),
                ),
                if (hasFile)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _formValues.remove(fieldId);
                        });
                        field.didChange(null);
                      },
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Remove file'),
                    ),
                  ),
                if (field.hasError)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 8),
                    child: Text(
                      field.errorText ?? '',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            );
          },
        );

      case 'name':
        return FormField<Map<String, String>>(
          initialValue: (_formValues[fieldId] as Map?)?.cast<String, String>(),
          validator:
              required
                  ? (v) {
                    if (v == null) return 'Required';
                    if (v['first']?.trim().isEmpty ?? true) {
                      return 'First name required';
                    }
                    if (v['last']?.trim().isEmpty ?? true) {
                      return 'Last name required';
                    }
                    return null;
                  }
                  : null,
          builder: (field) {
            final nameData =
                (_formValues[fieldId] as Map?)?.cast<String, String>() ?? {};
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  required ? '$label *' : label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < 560;
                    final firstNameField = TextFormField(
                      initialValue: nameData['first'],
                      decoration: const InputDecoration(
                        labelText: 'First Name',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) {
                        final updated = Map<String, String>.from(nameData);
                        updated['first'] = val;
                        setState(() => _formValues[fieldId] = updated);
                        field.didChange(updated);
                      },
                    );
                    final lastNameField = TextFormField(
                      initialValue: nameData['last'],
                      decoration: const InputDecoration(
                        labelText: 'Last Name',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) {
                        final updated = Map<String, String>.from(nameData);
                        updated['last'] = val;
                        setState(() => _formValues[fieldId] = updated);
                        field.didChange(updated);
                      },
                    );

                    if (isCompact) {
                      return Column(
                        children: [
                          firstNameField,
                          const SizedBox(height: 12),
                          lastNameField,
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(child: firstNameField),
                        const SizedBox(width: 12),
                        Expanded(child: lastNameField),
                      ],
                    );
                  },
                ),
                if (field.hasError)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 8),
                    child: Text(
                      field.errorText ?? '',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            );
          },
        );

      case 'address':
        return FormField<Map<String, String>>(
          initialValue: (_formValues[fieldId] as Map?)?.cast<String, String>(),
          validator:
              required
                  ? (v) {
                    if (v == null) return 'Required';
                    if (v['street']?.trim().isEmpty ?? true) {
                      return 'Street required';
                    }
                    if (v['city']?.trim().isEmpty ?? true) {
                      return 'City required';
                    }
                    if (v['province']?.trim().isEmpty ?? true) {
                      return 'Province required';
                    }
                    if (v['postal']?.trim().isEmpty ?? true) {
                      return 'Postal code required';
                    }
                    return null;
                  }
                  : null,
          builder: (field) {
            final addrData =
                (_formValues[fieldId] as Map?)?.cast<String, String>() ?? {};
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  required ? '$label *' : label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  initialValue: addrData['street'],
                  decoration: const InputDecoration(
                    labelText: 'Street Address',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (val) {
                    final updated = Map<String, String>.from(addrData);
                    updated['street'] = val;
                    setState(() => _formValues[fieldId] = updated);
                    field.didChange(updated);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: addrData['street2'],
                  decoration: const InputDecoration(
                    labelText: 'Apt, Suite, etc. (Optional)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (val) {
                    final updated = Map<String, String>.from(addrData);
                    updated['street2'] = val;
                    setState(() => _formValues[fieldId] = updated);
                    field.didChange(updated);
                  },
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < 640;
                    final cityField = TextFormField(
                      initialValue: addrData['city'],
                      decoration: const InputDecoration(
                        labelText: 'City',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) {
                        final updated = Map<String, String>.from(addrData);
                        updated['city'] = val;
                        setState(() => _formValues[fieldId] = updated);
                        field.didChange(updated);
                      },
                    );
                    final provinceField = TextFormField(
                      initialValue: addrData['province'],
                      decoration: const InputDecoration(
                        labelText: 'Province',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) {
                        final updated = Map<String, String>.from(addrData);
                        updated['province'] = val;
                        setState(() => _formValues[fieldId] = updated);
                        field.didChange(updated);
                      },
                    );
                    final postalField = TextFormField(
                      initialValue: addrData['postal'],
                      decoration: const InputDecoration(
                        labelText: 'Postal',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (val) {
                        final updated = Map<String, String>.from(addrData);
                        updated['postal'] = val;
                        setState(() => _formValues[fieldId] = updated);
                        field.didChange(updated);
                      },
                    );

                    if (isCompact) {
                      return Column(
                        children: [
                          cityField,
                          const SizedBox(height: 12),
                          provinceField,
                          const SizedBox(height: 12),
                          postalField,
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(flex: 2, child: cityField),
                        const SizedBox(width: 12),
                        Expanded(child: provinceField),
                        const SizedBox(width: 12),
                        Expanded(child: postalField),
                      ],
                    );
                  },
                ),
                if (field.hasError)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 8),
                    child: Text(
                      field.errorText ?? '',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            );
          },
        );

      case 'signature':
        return FormField<String>(
          initialValue: _formValues[fieldId] as String?,
          validator:
              required
                  ? (v) =>
                      v == null || v.isEmpty ? 'Signature is required' : null
                  : null,
          builder: (field) {
            final hasSignature =
                (_formValues[fieldId] as String?)?.isNotEmpty == true;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  required ? '$label *' : label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 150,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.white,
                  ),
                  child: Stack(
                    children: [
                      Center(
                        child: Text(
                          hasSignature ? '✓ Signed' : 'Sign Here',
                          style: TextStyle(
                            color: hasSignature ? Colors.green : Colors.grey,
                            fontSize: 18,
                            fontWeight:
                                hasSignature
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              // Simulate signature
                              setState(() {
                                _formValues[fieldId] =
                                    'SIGNED_${DateTime.now().millisecondsSinceEpoch}';
                              });
                              field.didChange(_formValues[fieldId] as String);
                              ScaffoldMessenger.of(context).showTryprSnackBar(
                                const SnackBar(
                                  content: Text('Signature captured'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                if (hasSignature)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        setState(() {
                          _formValues[fieldId] = '';
                        });
                        field.didChange('');
                      },
                      child: const Text('Clear'),
                    ),
                  ),
                if (field.hasError)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 8),
                    child: Text(
                      field.errorText ?? '',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            );
          },
        );

      default: // text
        return TextFormField(
          controller: controller,
          decoration: decoration,
          validator:
              required
                  ? (v) => (v?.trim().isEmpty ?? true) ? 'Required' : null
                  : null,
        );
    }
  }
}
