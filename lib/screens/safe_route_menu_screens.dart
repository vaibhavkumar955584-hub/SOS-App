import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/auth_controller.dart';
import '../controllers/contact_controller.dart';
import '../controllers/history_controller.dart';
import '../controllers/sos_controller.dart';
import '../controllers/sos_settings_controller.dart';

class EmergencyContactsScreen extends StatefulWidget {
  const EmergencyContactsScreen({super.key});

  @override
  State<EmergencyContactsScreen> createState() => _EmergencyContactsScreenState();
}

class _EmergencyContactsScreenState extends State<EmergencyContactsScreen> {
  final ContactController _contactController =
      ContactController.instanceOrCreate();
  final TextEditingController _addController = TextEditingController();

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  Future<void> _editContact(String currentValue) async {
    final editController = TextEditingController(text: currentValue);
    final updated = await Get.dialog<String>(
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Edit Contact'),
        content: TextField(
          controller: editController,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Phone number',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: editController.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    editController.dispose();

    if (updated == null || updated.isEmpty || updated == currentValue) {
      return;
    }

    await _contactController.updateContact(currentValue, updated);
  }

  Future<void> _confirmDelete(String value) async {
    final shouldDelete = await Get.dialog<bool>(
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete Contact?'),
        content: Text('Remove $value from emergency contacts?'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Get.back(result: true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (shouldDelete == true) {
      await _contactController.removeContact(value);
      Get.snackbar('Deleted', 'Emergency contact removed');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Emergency Contacts')),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _addController,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Add contact number',
                prefixIcon: const Icon(Icons.phone),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                final value = _addController.text.trim();
                if (value.isEmpty) return;
                await _contactController.addContact(value);
                _addController.clear();
              },
              icon: const Icon(Icons.add),
              label: const Text('Add Contact'),
            ),
            const SizedBox(height: 20),
            if (_contactController.contacts.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 64),
                child: Center(
                  child: Text('No emergency contacts added yet.'),
                ),
              ),
            ..._contactController.contacts.map(
              (contact) => Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFEDE7F6),
                    child: Icon(Icons.contact_phone, color: Colors.deepPurple),
                  ),
                  title: Text(contact),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => _editContact(contact),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _confirmDelete(contact),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SosTimerScreen extends StatelessWidget {
  SosTimerScreen({super.key});

  final SosSettingsController _settings = SosSettingsController.instanceOrCreate();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SOS Timer')),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Choose how long the SOS countdown should wait before sending.',
            ),
            const SizedBox(height: 20),
            ...[0, 5, 10].map(
              (seconds) => RadioListTile<int>(
                value: seconds,
                groupValue: _settings.activationDelaySeconds.value,
                onChanged: (value) {
                  if (value != null) {
                    _settings.setActivationDelay(value);
                  }
                },
                title: Text(
                  seconds == 0 ? 'Instant' : '$seconds seconds',
                ),
                subtitle: const Text('Applies to SOS activation delay'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _photoUrlController = TextEditingController();
  bool _loading = true;
  String? _uid;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _photoUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() => _loading = false);
      }
      return;
    }
    final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
    final data = doc.data() ?? {};
    _uid = user.uid;
    _nameController.text = (data['name'] ?? user.displayName ?? '').toString();
    _phoneController.text = (data['phone'] ?? '').toString();
    _emailController.text = (data['email'] ?? user.email ?? '').toString();
    _photoUrlController.text = (data['photoUrl'] ?? user.photoURL ?? '').toString();
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate() || _uid == null) return;

    final user = FirebaseAuth.instance.currentUser;
    final newEmail = _emailController.text.trim();
    final newName = _nameController.text.trim();
    final newPhone = _phoneController.text.trim();
    final newPhotoUrl = _photoUrlController.text.trim();

    await FirebaseFirestore.instance.collection('users').doc(_uid).set({
      'name': newName,
      'phone': newPhone,
      'email': newEmail,
      'photoUrl': newPhotoUrl,
    }, SetOptions(merge: true));

    var authNote = 'Profile updated successfully';
    if (user != null) {
      try {
        if (user.displayName != newName) {
          await user.updateDisplayName(newName);
        }
        if (newEmail.isNotEmpty && (user.email ?? '') != newEmail) {
          await user.verifyBeforeUpdateEmail(newEmail);
          authNote = 'Profile saved. Check your inbox to verify the new email address.';
        }
        if ((user.photoURL ?? '') != newPhotoUrl) {
          await user.updatePhotoURL(newPhotoUrl.isEmpty ? null : newPhotoUrl);
        }
      } catch (e) {
        debugPrint('Profile auth update failed: $e');
        authNote = 'Profile saved, but some account changes may need re-authentication.';
      }
    }

    Get.snackbar('Saved', authNote, snackPosition: SnackPosition.BOTTOM);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _uid == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No profile is available until you are signed in.'),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                Center(
                  child: CircleAvatar(
                    radius: 44,
                    backgroundColor: const Color(0xFFEDE7F6),
                    backgroundImage: _photoUrlController.text.trim().isNotEmpty
                        ? NetworkImage(_photoUrlController.text.trim())
                        : null,
                    child: _photoUrlController.text.trim().isEmpty
                        ? const Icon(Icons.person, size: 44, color: Colors.deepPurple)
                        : null,
                  ),
                ),
                const SizedBox(height: 20),
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(labelText: 'Name'),
                        validator: (value) =>
                            value == null || value.trim().isEmpty ? 'Enter a name' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _phoneController,
                        decoration: const InputDecoration(labelText: 'Phone number'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _emailController,
                        decoration: const InputDecoration(labelText: 'Email'),
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _photoUrlController,
                        decoration: const InputDecoration(labelText: 'Profile photo URL'),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _saveProfile,
                        icon: const Icon(Icons.save),
                        label: const Text('Save Profile'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class HistoryScreen extends StatelessWidget {
  HistoryScreen({super.key});

  final HistoryController _history = HistoryController.instanceOrCreate();
  final SosController _sosController = SosController.instanceOrCreate();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => Get.defaultDialog(
              title: 'Clear History?',
              middleText: 'This will remove the local activity log from this device.',
              textConfirm: 'Clear',
              textCancel: 'Cancel',
              confirmTextColor: Colors.white,
              onConfirm: () {
                _history.clearHistory();
                Get.back();
              },
            ),
          ),
        ],
      ),
      body: Obx(
        () {
          final query = _history.query.value.trim().toLowerCase();
          final filtered = _history.entries.where((entry) {
            if (query.isEmpty) return true;
            return entry.title.toLowerCase().contains(query) ||
                entry.subtitle.toLowerCase().contains(query) ||
                entry.type.toLowerCase().contains(query);
          }).toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                decoration: InputDecoration(
                  hintText: 'Search history',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onChanged: (value) => _history.query.value = value,
              ),
              const SizedBox(height: 16),
              _LastSosRecordingCard(controller: _sosController),
              const SizedBox(height: 16),
              if (filtered.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 80),
                  child: Center(child: Text('No history recorded yet.')),
                ),
              ...filtered.map(
                (entry) => Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _iconColor(entry.type).withOpacity(0.15),
                      child: Icon(_iconFor(entry.type), color: _iconColor(entry.type)),
                    ),
                    title: Text(entry.title),
                    subtitle: Text(entry.subtitle),
                    trailing: Text(
                      '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}',
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'sos':
        return Icons.sos;
      case 'unsafe':
        return Icons.warning_amber_rounded;
      case 'route':
        return Icons.route;
      default:
        return Icons.history;
    }
  }

  Color _iconColor(String type) {
    switch (type) {
      case 'sos':
        return Colors.red;
      case 'unsafe':
        return Colors.deepPurple;
      case 'route':
        return Colors.pink;
      default:
        return Colors.grey;
    }
  }
}

class _LastSosRecordingCard extends StatelessWidget {
  const _LastSosRecordingCard({required this.controller});

  final SosController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final displayPath = controller.lastRecordingDisplayPath;
      final hasRecording = controller.hasLastRecording;
      final isPrivateOnly = controller.isLastRecordingPrivateOnly;

      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.red.withOpacity(0.12),
                    child: const Icon(Icons.audio_file_outlined, color: Colors.red),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Last SOS Recording',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (!hasRecording)
                Text(
                  'No recording available',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                )
              else ...[
                if (isPrivateOnly)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Recording saved privately',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withOpacity(0.45),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: SelectableText(
                    displayPath,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => controller.copyLastRecordingPath(),
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('Copy Path'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => controller.openLastRecordingFile(),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open File'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => controller.shareLastRecordingFile(),
                      icon: const Icon(Icons.share_outlined),
                      label: const Text('Share Recording'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    });
  }
}

Future<void> showLogoutConfirmation() async {
  final confirmed = await Get.dialog<bool>(
    AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Logout?'),
      content: const Text('Are you sure you want to sign out of SafeRoute?'),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Get.back(result: true),
          child: const Text('Logout'),
        ),
      ],
    ),
  );

  if (confirmed == true) {
    await AuthController.instance.logout();
  }
}
