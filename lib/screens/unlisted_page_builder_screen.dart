import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:trypr/utils/trypr_snackbar.dart';
import 'package:flutter/services.dart';
import 'package:trypr/services/pick_image_data_url.dart';

/// Admin screen for creating/editing unlisted pages
class UnlistedPageBuilderScreen extends StatefulWidget {
  final String? existingPageId;
  final Map<String, dynamic>? existingPageData;

  const UnlistedPageBuilderScreen({
    super.key,
    this.existingPageId,
    this.existingPageData,
  });

  static Route<void> route({
    String? existingPageId,
    Map<String, dynamic>? existingPageData,
  }) {
    return MaterialPageRoute<void>(
      builder:
          (_) => UnlistedPageBuilderScreen(
            existingPageId: existingPageId,
            existingPageData: existingPageData,
          ),
    );
  }

  @override
  State<UnlistedPageBuilderScreen> createState() =>
      _UnlistedPageBuilderScreenState();
}

class _UnlistedPageBuilderScreenState extends State<UnlistedPageBuilderScreen> {
  final _formKey = GlobalKey<FormState>();

  final _titleCtl = TextEditingController();
  final _descriptionCtl = TextEditingController();
  final _contentCtl = TextEditingController();
  final _slugCtl = TextEditingController();
  final _formTitleCtl = TextEditingController(text: 'Sign Up');
  final _formButtonTextCtl = TextEditingController(text: 'Submit');

  String _coverImage = '';
  bool _formEnabled = true;
  List<Map<String, dynamic>> _formFields = [];

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _populateFromExisting();
  }

  @override
  void dispose() {
    _titleCtl.dispose();
    _descriptionCtl.dispose();
    _contentCtl.dispose();
    _slugCtl.dispose();
    _formTitleCtl.dispose();
    _formButtonTextCtl.dispose();
    super.dispose();
  }

  void _populateFromExisting() {
    final data = widget.existingPageData;
    if (data == null) {
      // Generate a random slug for new pages
      _slugCtl.text = _generateSlug();
      // Add default form fields
      _formFields = [
        {'id': 'name', 'label': 'Full Name', 'type': 'text', 'required': true},
        {'id': 'email', 'label': 'Email', 'type': 'email', 'required': true},
        {
          'id': 'phone',
          'label': 'Phone Number',
          'type': 'phone',
          'required': false,
        },
      ];
      return;
    }

    _titleCtl.text = data['title']?.toString() ?? '';
    _descriptionCtl.text = data['description']?.toString() ?? '';
    _contentCtl.text = data['content']?.toString() ?? '';
    _slugCtl.text = widget.existingPageId ?? '';
    _coverImage = data['coverImage']?.toString() ?? '';
    _formEnabled = data['formEnabled'] == true;
    _formTitleCtl.text = data['formTitle']?.toString() ?? 'Sign Up';
    _formButtonTextCtl.text = data['formButtonText']?.toString() ?? 'Submit';

    final fields = data['formFields'];
    if (fields is List) {
      _formFields =
          fields
              .whereType<Map>()
              .map((f) => Map<String, dynamic>.from(f))
              .toList();
    }
  }

  String _generateSlug() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = DateTime.now().millisecondsSinceEpoch;
    final buffer = StringBuffer();
    for (var i = 0; i < 8; i++) {
      buffer.write(chars[(random + i * 7) % chars.length]);
    }
    return buffer.toString();
  }

  Future<void> _pickCoverImage() async {
    final dataUrl = await pickImageDataUrl();
    if (dataUrl != null && mounted) {
      setState(() => _coverImage = dataUrl);
    }
  }

  void _addFormField() {
    setState(() {
      final id = 'field_${DateTime.now().millisecondsSinceEpoch}';
      _formFields.add({
        'id': id,
        'label': '',
        'type': 'text',
        'required': false,
        'hint': '',
        'options': [], // For dropdown, radio, checkbox
      });
    });
  }

  void _removeFormField(int index) {
    setState(() {
      _formFields.removeAt(index);
    });
  }

  void _updateFormField(int index, String key, dynamic value) {
    setState(() {
      _formFields[index][key] = value;
    });
  }

  ({Uint8List bytes, String contentType})? _decodeDataUrl(String dataUrl) {
    final raw = dataUrl.trim();
    if (!raw.startsWith('data:')) return null;
    final comma = raw.indexOf(',');
    if (comma <= 0) return null;

    final header = raw.substring(0, comma);
    final payload = raw.substring(comma + 1);

    String contentType = 'image/jpeg';
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

  String _extForContentType(String contentType) {
    final ct = contentType.toLowerCase();
    if (ct.contains('png')) return 'png';
    if (ct.contains('webp')) return 'webp';
    if (ct.contains('gif')) return 'gif';
    return 'jpg';
  }

  Future<String> _uploadImage(String pageId, String dataUrl) async {
    final decoded = _decodeDataUrl(dataUrl);
    if (decoded == null) throw Exception('Invalid image format');

    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = _extForContentType(decoded.contentType);
    final ref = FirebaseStorage.instance.ref(
      'unlistedPages/$pageId/cover_$ts.$ext',
    );

    final meta = SettableMetadata(contentType: decoded.contentType);
    final task = await ref.putData(decoded.bytes, meta);
    return task.ref.getDownloadURL();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('You must be signed in')),
      );
      return;
    }

    final slug = _slugCtl.text.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9-]'),
      '',
    );
    if (slug.isEmpty) {
      ScaffoldMessenger.of(context).showTryprSnackBar(
        const SnackBar(content: Text('Please enter a valid page ID/slug')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final isEditing = widget.existingPageId != null;
      final docRef = FirebaseFirestore.instance
          .collection('unlistedPages')
          .doc(slug);

      // Check if slug already exists (for new pages)
      if (!isEditing) {
        final existing = await docRef.get();
        if (existing.exists) {
          if (mounted) {
            ScaffoldMessenger.of(context).showTryprSnackBar(
              const SnackBar(
                content: Text(
                  'This page ID already exists. Choose a different one.',
                ),
              ),
            );
          }
          setState(() => _saving = false);
          return;
        }
      }

      // Upload cover image if it's a data URL
      String coverImage = _coverImage;
      if (coverImage.startsWith('data:image')) {
        coverImage = await _uploadImage(slug, coverImage);
      }

      final pageData = <String, dynamic>{
        'title': _titleCtl.text.trim(),
        'description': _descriptionCtl.text.trim(),
        'content': _contentCtl.text,
        'coverImage': coverImage,
        'formEnabled': _formEnabled,
        'formTitle': _formTitleCtl.text.trim(),
        'formButtonText': _formButtonTextCtl.text.trim(),
        'formFields': _formFields,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedByUid': user.uid,
      };

      if (!isEditing) {
        pageData['createdAt'] = FieldValue.serverTimestamp();
        pageData['createdByUid'] = user.uid;
      }

      await docRef.set(pageData, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(context).showTryprSnackBar(
          SnackBar(
            content: Text(isEditing ? 'Page updated' : 'Page created'),
            action: SnackBarAction(
              label: 'Copy Link',
              onPressed: () {
                final url = '${Uri.base.origin}/page/$slug';
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showTryprSnackBar(
                  const SnackBar(content: Text('Link copied to clipboard')),
                );
              },
            ),
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showTryprSnackBar(SnackBar(content: Text('Error saving: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _copyLink() {
    final slug = _slugCtl.text.trim();
    if (slug.isEmpty) return;
    final url = '${Uri.base.origin}/page/$slug';
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showTryprSnackBar(
      const SnackBar(content: Text('Link copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existingPageId != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Unlisted Page' : 'Create Unlisted Page'),
        actions: [
          if (_slugCtl.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.link),
              tooltip: 'Copy Link',
              onPressed: _copyLink,
            ),
          TextButton(
            onPressed: _saving ? null : _save,
            child:
                _saving
                    ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Text('Save'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Cover Image
            GestureDetector(
              onTap: _pickCoverImage,
              child: Container(
                height: 180,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(12),
                  image:
                      _coverImage.isNotEmpty
                          ? DecorationImage(
                            image: NetworkImage(_coverImage),
                            fit: BoxFit.cover,
                            onError: (_, __) {},
                          )
                          : null,
                ),
                child:
                    _coverImage.isEmpty
                        ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.add_photo_alternate,
                              size: 48,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Add Cover Image',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          ],
                        )
                        : null,
              ),
            ),
            const SizedBox(height: 24),

            // Page Settings Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Page Settings',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _titleCtl,
                      decoration: const InputDecoration(
                        labelText: 'Page Title *',
                        hintText: 'e.g., Boy Scouts Bikepacking Trip 2026',
                      ),
                      validator:
                          (v) =>
                              (v?.trim().isEmpty ?? true) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _slugCtl,
                      decoration: InputDecoration(
                        labelText: 'Page ID (URL slug) *',
                        hintText: 'e.g., scouts-bikepack-2026',
                        helperText: 'This will be part of the shareable link',
                        prefixText: '/page/',
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.refresh),
                          tooltip: 'Generate new ID',
                          onPressed: () {
                            setState(() {
                              _slugCtl.text = _generateSlug();
                            });
                          },
                        ),
                      ),
                      enabled: widget.existingPageId == null,
                      validator:
                          (v) =>
                              (v?.trim().isEmpty ?? true) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _descriptionCtl,
                      decoration: const InputDecoration(
                        labelText: 'Short Description',
                        hintText: 'A brief summary of this page',
                      ),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Content Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Page Content',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Use ## for headings, ### for subheadings, and - for bullet points',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _contentCtl,
                      decoration: const InputDecoration(
                        labelText: 'Content',
                        hintText:
                            '## Trip Details\n\nWe will be biking through...\n\n### What to Bring\n- Bike\n- Helmet\n- Camping gear',
                        alignLabelWithHint: true,
                      ),
                      maxLines: 12,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Form Settings Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Sign-up Form',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                'Collect responses from visitors',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: _formEnabled,
                          onChanged: (v) => setState(() => _formEnabled = v),
                          activeThumbColor: const Color(0xFF00B894),
                        ),
                      ],
                    ),

                    if (_formEnabled) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _formTitleCtl,
                              decoration: const InputDecoration(
                                labelText: 'Form Title',
                                hintText: 'Sign Up',
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextFormField(
                              controller: _formButtonTextCtl,
                              decoration: const InputDecoration(
                                labelText: 'Button Text',
                                hintText: 'Submit',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      const Text(
                        'Form Fields',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),

                      ...List.generate(_formFields.length, (index) {
                        final field = _formFields[index];
                        return _FormFieldEditor(
                          key: ValueKey(field['id']),
                          field: field,
                          onUpdate:
                              (key, value) =>
                                  _updateFormField(index, key, value),
                          onRemove: () => _removeFormField(index),
                        );
                      }),

                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _addFormField,
                        icon: const Icon(Icons.add),
                        label: const Text('Add Field'),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _OptionsEditor extends StatefulWidget {
  final List<String> options;
  final ValueChanged<List<String>> onChanged;

  const _OptionsEditor({required this.options, required this.onChanged});

  @override
  State<_OptionsEditor> createState() => _OptionsEditorState();
}

class _OptionsEditorState extends State<_OptionsEditor> {
  late List<String> _options;
  final _controllers = <TextEditingController>[];

  @override
  void initState() {
    super.initState();
    _options = List<String>.from(widget.options);
    if (_options.isEmpty) {
      _options = ['Option 1', 'Option 2'];
    }
    for (final opt in _options) {
      _controllers.add(TextEditingController(text: opt));
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _addOption() {
    setState(() {
      final newOpt = 'Option ${_options.length + 1}';
      _options.add(newOpt);
      _controllers.add(TextEditingController(text: newOpt));
      widget.onChanged(_options);
    });
  }

  void _removeOption(int index) {
    if (_options.length <= 1) return; // Keep at least one option
    setState(() {
      _options.removeAt(index);
      _controllers[index].dispose();
      _controllers.removeAt(index);
      widget.onChanged(_options);
    });
  }

  void _updateOption(int index, String value) {
    _options[index] = value;
    widget.onChanged(_options);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.list, size: 16, color: Colors.blue),
              const SizedBox(width: 6),
              const Text(
                'Options',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  color: Colors.blue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...List.generate(_options.length, (index) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _controllers[index],
                      decoration: InputDecoration(
                        labelText: 'Option ${index + 1}',
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      onChanged: (v) => _updateOption(index, v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                    color: Colors.red,
                    onPressed:
                        _options.length > 1 ? () => _removeOption(index) : null,
                    tooltip: 'Remove option',
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: _addOption,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add Option'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.blue,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
        ],
      ),
    );
  }
}

class _FormFieldEditor extends StatelessWidget {
  final Map<String, dynamic> field;
  final void Function(String key, dynamic value) onUpdate;
  final VoidCallback onRemove;

  const _FormFieldEditor({
    super.key,
    required this.field,
    required this.onUpdate,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  initialValue: field['label']?.toString() ?? '',
                  decoration: const InputDecoration(
                    labelText: 'Label',
                    isDense: true,
                  ),
                  onChanged: (v) => onUpdate('label', v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: field['type']?.toString() ?? 'text',
                  decoration: const InputDecoration(
                    labelText: 'Type',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'text', child: Text('Text')),
                    DropdownMenuItem(value: 'email', child: Text('Email')),
                    DropdownMenuItem(value: 'phone', child: Text('Phone')),
                    DropdownMenuItem(value: 'number', child: Text('Number')),
                    DropdownMenuItem(
                      value: 'textarea',
                      child: Text('Long Text'),
                    ),
                    DropdownMenuItem(
                      value: 'dropdown',
                      child: Text('Dropdown'),
                    ),
                    DropdownMenuItem(
                      value: 'radio',
                      child: Text('Radio Buttons'),
                    ),
                    DropdownMenuItem(
                      value: 'checkbox',
                      child: Text('Checkboxes'),
                    ),
                    DropdownMenuItem(value: 'date', child: Text('Date')),
                    DropdownMenuItem(value: 'file', child: Text('File Upload')),
                    DropdownMenuItem(value: 'name', child: Text('Full Name')),
                    DropdownMenuItem(value: 'address', child: Text('Address')),
                    DropdownMenuItem(
                      value: 'signature',
                      child: Text('Signature'),
                    ),
                  ],
                  onChanged: (v) => onUpdate('type', v),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: onRemove,
                tooltip: 'Remove field',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: field['hint']?.toString() ?? '',
                  decoration: const InputDecoration(
                    labelText: 'Hint/Placeholder',
                    isDense: true,
                  ),
                  onChanged: (v) => onUpdate('hint', v),
                ),
              ),
              const SizedBox(width: 12),
              Row(
                children: [
                  Checkbox(
                    value: field['required'] == true,
                    onChanged: (v) => onUpdate('required', v ?? false),
                  ),
                  const Text('Required'),
                ],
              ),
            ],
          ),
          // Options editor for dropdown, radio, checkbox
          if (field['type'] == 'dropdown' ||
              field['type'] == 'radio' ||
              field['type'] == 'checkbox') ...[
            const SizedBox(height: 12),
            _OptionsEditor(
              options: (field['options'] as List?)?.cast<String>() ?? [],
              onChanged: (newOptions) => onUpdate('options', newOptions),
            ),
          ],
        ],
      ),
    );
  }
}
