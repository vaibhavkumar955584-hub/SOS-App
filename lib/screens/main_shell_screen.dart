import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../theme/app_colors.dart';
import '../controllers/auth_controller.dart';
import '../controllers/contact_controller.dart';
import '../controllers/history_controller.dart';
import 'map_screen.dart';
import 'emergency_sos_screen.dart';
import 'permissions_onboarding_screen.dart';
import '../services/pending_action_service.dart';
import '../controllers/journey_guard_controller.dart';
import '../controllers/rescue_stats_controller.dart';

class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key});

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen> {
  int _currentIndex = 0;
  final AuthController _authController = Get.find<AuthController>();

  bool _isCommunityWatchEnabled = false;
  bool _isShakeModeActive = true;
  bool _isVoiceModeActive = true;
  String _selectedHistoryFilter = 'ALL';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndRecoverPendingAction();
    });
  }

  Future<void> _checkAndRecoverPendingAction() async {
    final action = await PendingActionService.getPendingAction();
    final savedRouteIndex = await PendingActionService.getSavedRouteIndex();

    if (savedRouteIndex != null && savedRouteIndex >= 0 && savedRouteIndex < 4) {
      if (mounted) {
        setState(() {
          _currentIndex = savedRouteIndex;
        });
      }
    }

    if (action == PendingExternalAction.profileImagePicker) {
      debugPrint('[SafeRoute] External action recovered: profileImagePicker');
      try {
        const channel = MethodChannel('safe_route/sms');
        final Map<dynamic, dynamic>? res = await channel.invokeMethod('getPendingProfileImage');
        if (res?['hasPending'] == true && res?['imagePath'] != null) {
          final imagePath = res!['imagePath'].toString();
          final user = FirebaseAuth.instance.currentUser;
          if (user != null) {
            await user.updatePhotoURL(imagePath);
            await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
              'photoURL': imagePath,
            }, SetOptions(merge: true));
            if (mounted) {
              setState(() {});
              Get.snackbar(
                'Profile Photo Recovered',
                'Your selected profile image from gallery has been saved.',
                snackPosition: SnackPosition.TOP,
                backgroundColor: AppColors.safetyGreen,
                colorText: Colors.black,
              );
              _showEditProfileDialog(context);
            }
          }
        }
      } catch (e) {
        debugPrint('[SafeRoute] Error recovering profile image: $e');
      } finally {
        await PendingActionService.clearPendingAction();
      }
    } else if (action == PendingExternalAction.contactPicker) {
      debugPrint('[SafeRoute] External action recovered: contactPicker');
      try {
        final contactController = ContactController.instanceOrCreate();
        await contactController.checkPendingPickedContact();
        if (mounted) {
          setState(() {
            _currentIndex = 2;
          });
        }
      } catch (e) {
        debugPrint('[SafeRoute] Error recovering contact picker: $e');
      } finally {
        await PendingActionService.clearPendingAction();
      }
    }
  }

  Widget _buildUserAvatar(User? user, String userName, {double radius = 24}) {
    final photoUrl = user?.photoURL;
    if (photoUrl != null && photoUrl.isNotEmpty) {
      if (photoUrl.startsWith('/') || photoUrl.startsWith('file://')) {
        final filePath = photoUrl.replaceFirst('file://', '');
        final file = File(filePath);
        if (file.existsSync()) {
          return CircleAvatar(
            radius: radius,
            backgroundImage: FileImage(file),
          );
        }
      } else if (photoUrl.startsWith('http')) {
        return CircleAvatar(
          radius: radius,
          backgroundImage: NetworkImage(photoUrl),
        );
      } else if (photoUrl == 'preset:shield') {
        return CircleAvatar(
          radius: radius,
          backgroundColor: AppColors.safetyGreen,
          child: Icon(Icons.shield, color: Colors.black, size: radius * 1.1),
        );
      } else if (photoUrl == 'preset:security') {
        return CircleAvatar(
          radius: radius,
          backgroundColor: AppColors.softCyan,
          child: Icon(Icons.security, color: Colors.black, size: radius * 1.1),
        );
      } else if (photoUrl == 'preset:face') {
        return CircleAvatar(
          radius: radius,
          backgroundColor: Colors.amberAccent,
          child: Icon(Icons.face, color: Colors.black, size: radius * 1.1),
        );
      }
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.primaryContainer,
      child: Text(
        userName.isNotEmpty ? userName[0].toUpperCase() : 'U',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: radius * 0.9, color: Colors.black),
      ),
    );
  }

  void _showProfilePopover(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final userName = user?.displayName?.isNotEmpty == true ? user!.displayName! : (user?.email?.split('@').first ?? 'SafeRoute User');
    final userEmail = user?.email ?? 'protected@saferoute.app';
    final contactsList = ContactController.instanceOrCreate().contacts;
    final bool hasContacts = contactsList.isNotEmpty;
    final String securityBadge = hasContacts ? 'Secure' : '1 Alert';

    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (popoverContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          alignment: Alignment.topRight,
          insetPadding: const EdgeInsets.only(top: 60, right: 16),
          child: Container(
            width: 280,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // User Header
                Row(
                  children: [
                    _buildUserAvatar(user, userName, radius: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            userName,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: AppColors.onSurface,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            userEmail,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              color: AppColors.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(color: AppColors.borderSubtle, height: 1),
                const SizedBox(height: 8),

                // Menu Items
                _buildProfileMenuItem(
                  icon: Icons.person_outline,
                  label: 'Edit Profile',
                  onTap: () {
                    Navigator.pop(popoverContext);
                    _showEditProfileDialog(context);
                  },
                ),
                _buildProfileMenuItem(
                  icon: Icons.settings_outlined,
                  label: 'App Settings',
                  onTap: () {
                    Navigator.pop(popoverContext);
                    _showAppSettingsDialog(context);
                  },
                ),
                _buildProfileMenuItem(
                  icon: Icons.shield_outlined,
                  label: 'Privacy & Security',
                  badge: securityBadge,
                  onTap: () {
                    Navigator.pop(popoverContext);
                    _showPrivacySecurityDialog(context, hasContacts: hasContacts);
                  },
                ),
                const SizedBox(height: 8),
                const Divider(color: AppColors.borderSubtle, height: 1),
                const SizedBox(height: 8),

                _buildProfileMenuItem(
                  icon: Icons.logout_rounded,
                  label: 'Sign Out',
                  isDestructive: true,
                  onTap: () {
                    Navigator.pop(popoverContext);
                    _authController.logout();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showEditProfileDialog(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final nameController = TextEditingController(text: user?.displayName ?? '');
    final emailController = TextEditingController(text: user?.email ?? '');
    final photoUrlController = TextEditingController(text: user?.photoURL?.startsWith('http') == true ? user!.photoURL! : '');
    String selectedAvatar = user?.photoURL ?? 'preset:initials';

    Get.dialog(
      StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            backgroundColor: AppColors.surfaceContainer,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Edit User Profile', style: TextStyle(color: AppColors.onSurface, fontFamily: 'Manrope', fontWeight: FontWeight.bold)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      _buildUserAvatar(user, nameController.text.isNotEmpty ? nameController.text : 'U', radius: 36),
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(color: AppColors.safetyGreen, shape: BoxShape.circle),
                        child: const Icon(Icons.camera_alt, size: 14, color: Colors.black),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('Select Profile Avatar', style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: () => setModalState(() => selectedAvatar = 'preset:initials'),
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: selectedAvatar == 'preset:initials' ? AppColors.safetyGreen : AppColors.surfaceContainerHigh,
                          child: const Icon(Icons.person, size: 20, color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setModalState(() => selectedAvatar = 'preset:shield'),
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: selectedAvatar == 'preset:shield' ? AppColors.safetyGreen : AppColors.surfaceContainerHigh,
                          child: const Icon(Icons.shield, size: 20, color: AppColors.safetyGreen),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setModalState(() => selectedAvatar = 'preset:security'),
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: selectedAvatar == 'preset:security' ? AppColors.safetyGreen : AppColors.surfaceContainerHigh,
                          child: const Icon(Icons.security, size: 20, color: AppColors.softCyan),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setModalState(() => selectedAvatar = 'preset:face'),
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: selectedAvatar == 'preset:face' ? AppColors.safetyGreen : AppColors.surfaceContainerHigh,
                          child: const Icon(Icons.face, size: 20, color: Colors.amberAccent),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          await PendingActionService.savePendingAction(
                            action: PendingExternalAction.profileImagePicker,
                            routeIndex: 0,
                            tempName: nameController.text.trim(),
                          );
                          const channel = MethodChannel('safe_route/sms');
                          final Map<dynamic, dynamic>? res = await channel.invokeMethod('pickImageFromGallery');
                          if (res?['success'] == true && res?['imagePath'] != null) {
                            final imagePath = res!['imagePath'].toString();
                            setModalState(() {
                              selectedAvatar = imagePath;
                            });
                          }
                        } catch (e) {
                          Get.snackbar("Gallery Error", "Unable to pick photo from gallery.");
                        } finally {
                          await PendingActionService.clearPendingAction();
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.safetyGreen,
                        side: const BorderSide(color: AppColors.safetyGreen),
                      ),
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: const Text('Choose Photo from Gallery'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameController,
                    style: const TextStyle(color: AppColors.onSurface),
                    decoration: const InputDecoration(
                      labelText: 'Full Name',
                      labelStyle: TextStyle(color: AppColors.onSurfaceVariant),
                      prefixIcon: Icon(Icons.person_outline, color: AppColors.onSurfaceVariant),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: photoUrlController,
                    style: const TextStyle(color: AppColors.onSurface),
                    decoration: const InputDecoration(
                      labelText: 'Custom Photo URL (Optional)',
                      labelStyle: TextStyle(color: AppColors.onSurfaceVariant),
                      prefixIcon: Icon(Icons.link, color: AppColors.onSurfaceVariant),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      if (val.trim().startsWith('http')) {
                        setModalState(() => selectedAvatar = val.trim());
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: emailController,
                    readOnly: true,
                    style: const TextStyle(color: AppColors.onSurfaceVariant),
                    decoration: const InputDecoration(
                      labelText: 'Email Address (Verified)',
                      labelStyle: TextStyle(color: AppColors.onSurfaceVariant),
                      prefixIcon: Icon(Icons.email_outlined, color: AppColors.onSurfaceVariant),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Get.back(),
                child: const Text('Cancel', style: TextStyle(color: AppColors.onSurfaceVariant)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.safetyGreen, foregroundColor: Colors.black),
                onPressed: () async {
                  final newName = nameController.text.trim();
                  final finalPhotoUrl = photoUrlController.text.trim().startsWith('http')
                      ? photoUrlController.text.trim()
                      : selectedAvatar;

                  if (user != null) {
                    if (newName.isNotEmpty) {
                      await user.updateDisplayName(newName);
                    }
                    await user.updatePhotoURL(finalPhotoUrl);
                    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
                      'name': newName,
                      'photoURL': finalPhotoUrl,
                    }, SetOptions(merge: true));

                    setState(() {});
                    Get.snackbar('Profile Updated', 'Your profile details and avatar have been saved.');
                  }
                  Get.back();
                },
                child: const Text('Save Profile'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showAppSettingsDialog(BuildContext context) {
    bool shakeTriggerEnabled = true;
    bool silentSmsEnabled = true;
    bool highAccuracyGps = true;

    Get.dialog(
      StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            backgroundColor: AppColors.surfaceContainer,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('App Settings', style: TextStyle(color: AppColors.onSurface, fontFamily: 'Manrope', fontWeight: FontWeight.bold)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: const Text('Shake Hardware Sensor', style: TextStyle(color: AppColors.onSurface, fontSize: 14)),
                  subtitle: const Text('Auto-dispatch SOS on physical shake', style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 12)),
                  value: shakeTriggerEnabled,
                  activeThumbColor: AppColors.safetyGreen,
                  onChanged: (val) => setModalState(() => shakeTriggerEnabled = val),
                ),
                SwitchListTile(
                  title: const Text('Silent SIM Hardware SMS', style: TextStyle(color: AppColors.onSurface, fontSize: 14)),
                  subtitle: const Text('Background dispatch without app popups', style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 12)),
                  value: silentSmsEnabled,
                  activeThumbColor: AppColors.safetyGreen,
                  onChanged: (val) => setModalState(() => silentSmsEnabled = val),
                ),
                SwitchListTile(
                  title: const Text('High Accuracy GPS Engine', style: TextStyle(color: AppColors.onSurface, fontSize: 14)),
                  subtitle: const Text('5-tier real-time fallback active', style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 12)),
                  value: highAccuracyGps,
                  activeThumbColor: AppColors.safetyGreen,
                  onChanged: (val) => setModalState(() => highAccuracyGps = val),
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.safetyGreen, foregroundColor: Colors.black),
                onPressed: () {
                  Get.back();
                  Get.snackbar('Settings Saved', 'App hardware configurations updated.');
                },
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showPrivacySecurityDialog(BuildContext context, {bool hasContacts = true}) {
    Get.dialog(
      AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Privacy & Security', style: TextStyle(color: AppColors.onSurface, fontFamily: 'Manrope', fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: hasContacts ? AppColors.primaryContainer.withValues(alpha: 0.15) : AppColors.secondaryContainer.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(hasContacts ? Icons.security : Icons.warning_amber_rounded, color: hasContacts ? AppColors.safetyGreen : AppColors.signalRed, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      hasContacts
                          ? 'End-to-End Encryption & Hardware Lock Active'
                          : 'SECURITY ALERT: No Emergency Contacts Configured!',
                      style: TextStyle(color: hasContacts ? AppColors.safetyGreen : AppColors.signalRed, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text('Hardware Permissions & Security', style: TextStyle(color: AppColors.onSurface, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 4),
            Text(
              hasContacts
                  ? 'All 5 core permissions granted and contacts verified for emergency dispatch.'
                  : 'Add at least 1 emergency contact in the CONTACTS tab to clear this security alert.',
              style: const TextStyle(color: AppColors.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Get.back();
                  Get.to(() => const PermissionsOnboardingScreen());
                },
                icon: const Icon(Icons.verified_user_outlined, color: AppColors.safetyGreen, size: 18),
                label: const Text('Re-verify Permissions Flow', style: TextStyle(color: AppColors.onSurface)),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.safetyGreen, foregroundColor: Colors.black),
            onPressed: () => Get.back(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileMenuItem({
    required IconData icon,
    required String label,
    String? badge,
    bool isDestructive = false,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: isDestructive ? AppColors.signalRed : AppColors.onSurface,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: isDestructive ? AppColors.signalRed : AppColors.onSurface,
                ),
              ),
            ),
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.signalRed,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        toolbarHeight: 64,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.shield_outlined, color: AppColors.safetyGreen, size: 20),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AppColors.safetyGreen,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'JOURNEY GUARD ACTIVE',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.safetyGreen,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    _getAppBarTitle(),
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: () => _showProfilePopover(context),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.safetyGreen, width: 2),
                ),
                child: const CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.surfaceContainerHigh,
                  child: Icon(Icons.person, color: AppColors.onSurface, size: 20),
                ),
              ),
            ),
          ],
        ),
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _buildOverviewTab(),
          const MapScreen(),
          _buildContactsTab(),
          _buildHistoryTab(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceContainerLow,
          border: Border(top: BorderSide(color: AppColors.borderSubtle, width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) => setState(() => _currentIndex = index),
          backgroundColor: AppColors.surfaceContainerLow,
          selectedItemColor: AppColors.safetyGreen,
          unselectedItemColor: AppColors.onSurfaceVariant,
          selectedLabelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.bold),
          unselectedLabelStyle: const TextStyle(fontFamily: 'Inter', fontSize: 11),
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.grid_view_rounded),
              label: 'OVERVIEW',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.explore_outlined),
              label: 'MAP',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.people_outline),
              label: 'CONTACTS',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.history_toggle_off),
              label: 'HISTORY',
            ),
          ],
        ),
      ),
    );
  }

  String _getAppBarTitle() {
    switch (_currentIndex) {
      case 0:
        return 'Overview';
      case 1:
        return 'Live Map';
      case 2:
        return 'Trusted Contacts';
      case 3:
        return 'History';
      default:
        return 'Overview';
    }
  }

  // --- TAB 1: OVERVIEW SCREEN ---
  Widget _buildOverviewTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // System Status Card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderSubtle, width: 1),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'SYSTEM STATUS',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: AppColors.onSurfaceVariant,
                          letterSpacing: 1.0,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'All Clear',
                        style: TextStyle(
                          fontFamily: 'Manrope',
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: AppColors.safetyGreen,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Your local environment and recent routes show no active alerts or anomalies.',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          color: AppColors.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.primaryContainer.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.shield_rounded, color: AppColors.safetyGreen, size: 28),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Total Rescue Counter Showcase Card
          Obx(() {
            final statsCtrl = Get.isRegistered<RescueStatsController>()
                ? Get.find<RescueStatsController>()
                : Get.put(RescueStatsController(), permanent: true);
            final totalRescues = statsCtrl.totalRescues.value;
            final personalRescues = statsCtrl.personalHelpedRescues.value;

            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.safetyGreen.withValues(alpha: 0.3), width: 1.5),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4)),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.safetyGreen.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.health_and_safety_rounded, color: AppColors.safetyGreen, size: 32),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'TOTAL RESCUES COMPLETED',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: AppColors.safetyGreen,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$totalRescues+ Lives Guarded',
                          style: const TextStyle(
                            fontFamily: 'Manrope',
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          personalRescues > 0
                              ? 'You helped in $personalRescues community rescues'
                              : 'Real-time emergency monitoring active',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 16),

          // Action Buttons Grid (Start Guard / Emergency SOS)
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _currentIndex = 1); // Switch to map tab
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      JourneyGuardController.instanceOrCreate().enterSelectDestinationMode();
                    });
                  },
                  child: Container(
                    height: 140,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainer,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.borderSubtle, width: 1),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: const BoxDecoration(
                            color: AppColors.safetyGreen,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.center_focus_strong, color: Colors.black, size: 24),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Start Guard',
                          style: TextStyle(
                            fontFamily: 'Manrope',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    Get.to(() => const EmergencySosScreen());
                  },
                  child: Container(
                    height: 140,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFB9000D), Color(0xFF8B0000)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.signalRed.withValues(alpha: 0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Text(
                            'SOS',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Emergency',
                          style: TextStyle(
                            fontFamily: 'Manrope',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Safety Trigger Modes Section
          const Text(
            'EMERGENCY TRIGGER MODES & HARDWARE CONTROLS',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: AppColors.onSurfaceVariant,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 12),

          // Shake Hardware Sensor Card
          StatefulBuilder(
            builder: (context, setModeState) {
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _isShakeModeActive ? AppColors.safetyGreen.withValues(alpha: 0.2) : AppColors.surfaceContainerHigh,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.vibration,
                        color: _isShakeModeActive ? AppColors.safetyGreen : AppColors.onSurfaceVariant,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Shake Hardware Trigger Mode',
                            style: TextStyle(fontFamily: 'Manrope', fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.onSurface),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _isShakeModeActive ? 'Auto-dispatches SOS on physical phone shake' : 'Disabled • Tap toggle to activate',
                            style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: AppColors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _isShakeModeActive,
                      activeThumbColor: AppColors.safetyGreen,
                      onChanged: (val) {
                        setState(() => _isShakeModeActive = val);
                        setModeState(() {});
                        Get.snackbar(
                          val ? 'Shake Detection Enabled' : 'Shake Detection Disabled',
                          val ? 'Physical phone shake will trigger emergency dispatch.' : 'Shake trigger turned off.',
                          snackPosition: SnackPosition.TOP,
                          backgroundColor: val ? AppColors.safetyGreen : Colors.orange,
                          colorText: Colors.black,
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),

          // Voice Detection Mode Card
          StatefulBuilder(
            builder: (context, setModeState) {
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _isVoiceModeActive ? AppColors.softCyan.withValues(alpha: 0.2) : AppColors.surfaceContainerHigh,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.mic_rounded,
                        color: _isVoiceModeActive ? AppColors.softCyan : AppColors.onSurfaceVariant,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Voice Activation Trigger Mode',
                            style: TextStyle(fontFamily: 'Manrope', fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.onSurface),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _isVoiceModeActive ? 'Keywords active: "HELP", "SOS", "SAVIOR"' : 'Disabled • Tap toggle to activate',
                            style: const TextStyle(fontFamily: 'Inter', fontSize: 11, color: AppColors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _isVoiceModeActive,
                      activeThumbColor: AppColors.softCyan,
                      onChanged: (val) {
                        setState(() => _isVoiceModeActive = val);
                        setModeState(() {});
                        Get.snackbar(
                          val ? 'Voice Trigger Enabled' : 'Voice Trigger Disabled',
                          val ? 'Voice keywords "HELP", "SOS" will trigger emergency.' : 'Voice mode turned off.',
                          snackPosition: SnackPosition.TOP,
                          backgroundColor: val ? AppColors.softCyan : Colors.orange,
                          colorText: Colors.black,
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),

          // Stealth Duress PIN & Hardware Lock Card
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderSubtle, width: 1),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.purple.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock_outline_rounded, color: Colors.purpleAccent, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'Stealth Duress PIN Mode (9999)',
                        style: TextStyle(fontFamily: 'Manrope', fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.onSurface),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Entering 9999 triggers silent SOS without alerting attackers.',
                        style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: AppColors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Get.snackbar(
                      'Duress PIN Active',
                      'Duress PIN is set to 9999 for silent distress dispatch.',
                      snackPosition: SnackPosition.TOP,
                      backgroundColor: Colors.purpleAccent,
                      colorText: Colors.white,
                    );
                  },
                  child: const Text('Active', style: TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Trusted Network Card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderSubtle, width: 1),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Trusted Network',
                      style: TextStyle(
                        fontFamily: 'Manrope',
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.onSurface,
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _currentIndex = 2),
                      child: Row(
                        children: const [
                          Text('Manage', style: TextStyle(color: AppColors.safetyGreen)),
                          Icon(Icons.chevron_right, color: AppColors.safetyGreen, size: 18),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Obx(() {
                  final contactController = ContactController.instanceOrCreate();
                  final contacts = contactController.contacts;
                  final bool isHardwareActive = contactController.isSmsPermissionGranted.value;

                  if (contacts.isEmpty) {
                    return Container(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: const [
                          Icon(Icons.person_add_disabled_outlined, color: AppColors.onSurfaceVariant, size: 28),
                          SizedBox(height: 6),
                          Text(
                            'No Emergency Contacts Added',
                            style: TextStyle(fontFamily: 'Inter', fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.onSurface),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Tap "Manage" to configure emergency contacts.',
                            style: TextStyle(fontFamily: 'Inter', fontSize: 11, color: AppColors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    );
                  }

                  return Column(
                    children: List.generate(contacts.length, (index) {
                      final phone = contacts[index];
                      final label = 'Contact ${index + 1}: $phone';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: _buildNetworkUserTile(
                          name: label,
                          subtitle: isHardwareActive ? 'Ready for SOS Dispatch • Online' : 'Hardware Permission Pending',
                          isOnline: isHardwareActive,
                          verified: true,
                        ),
                      );
                    }),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Recent Routes Card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderSubtle, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Recent Routes',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                _buildRouteItem(
                  title: 'Evening Commute',
                  time: 'Yesterday, 6:45 PM • Safe Arrival',
                  isTop: true,
                ),
                _buildRouteItem(
                  title: 'Morning Run',
                  time: 'Yesterday, 6:30 AM • Safe Arrival',
                  isTop: false,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNetworkUserTile({
    required String name,
    required String subtitle,
    required bool isOnline,
    required bool verified,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Stack(
            children: [
              const CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.surfaceContainerHigh,
                child: Icon(Icons.person, color: AppColors.onSurface, size: 20),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: isOnline ? AppColors.safetyGreen : Colors.grey,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.surfaceContainerLow, width: 2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (verified)
            const Icon(Icons.verified_rounded, color: AppColors.safetyGreen, size: 18),
        ],
      ),
    );
  }

  Widget _buildRouteItem({required String title, required String time, required bool isTop}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: AppColors.safetyGreen,
                shape: BoxShape.circle,
              ),
            ),
            if (isTop)
              Container(
                width: 2,
                height: 36,
                color: AppColors.borderSubtle,
              ),
          ],
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                time,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  color: AppColors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    );
  }

  // --- TAB 3: TRUSTED CONTACTS TAB ---
  Future<void> _showAddContactDialog(BuildContext context) async {
    final controller = ContactController.instanceOrCreate();
    final textController = TextEditingController();
    await Get.dialog(
      AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Add Trusted Contact', style: TextStyle(color: AppColors.onSurface)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: textController,
              keyboardType: TextInputType.phone,
              style: const TextStyle(color: AppColors.onSurface),
              decoration: const InputDecoration(
                hintText: 'Enter phone number (e.g. +1234567890)',
                hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  Get.back();
                  await controller.pickContactFromPhonebook();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.safetyGreen,
                  side: const BorderSide(color: AppColors.safetyGreen),
                ),
                icon: const Icon(Icons.contacts_outlined, size: 18),
                label: const Text('Pick from Device Phonebook'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('Cancel', style: TextStyle(color: AppColors.onSurfaceVariant)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.safetyGreen, foregroundColor: Colors.black),
            onPressed: () async {
              final val = textController.text.trim();
              if (val.isNotEmpty) {
                await controller.addContact(val);
                Get.back();
              }
            },
            child: const Text('Save Contact'),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditContactDialog(BuildContext context, String currentPhone) async {
    final controller = ContactController.instanceOrCreate();
    final textController = TextEditingController(text: currentPhone);
    await Get.dialog(
      AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Edit Trusted Contact', style: TextStyle(color: AppColors.onSurface)),
        content: TextField(
          controller: textController,
          keyboardType: TextInputType.phone,
          style: const TextStyle(color: AppColors.onSurface),
          decoration: const InputDecoration(
            hintText: 'Enter updated phone number',
            hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await controller.removeContact(currentPhone);
              Get.back();
            },
            child: const Text('Delete', style: TextStyle(color: AppColors.signalRed)),
          ),
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('Cancel', style: TextStyle(color: AppColors.onSurfaceVariant)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.safetyGreen, foregroundColor: Colors.black),
            onPressed: () async {
              final val = textController.text.trim();
              if (val.isNotEmpty && val != currentPhone) {
                await controller.updateContact(currentPhone, val);
              }
              Get.back();
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  // --- TAB 3: TRUSTED CONTACTS TAB ---
  Widget _buildContactsTab() {
    final contactController = ContactController.instanceOrCreate();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Trusted Contacts',
            style: TextStyle(
              fontFamily: 'Manrope',
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Manage who receives alerts during an emergency.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),

          // Primary Responders Section
          const Text(
            'Emergency Contacts List',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Obx(
            () => Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.borderSubtle, width: 1),
              ),
              child: contactController.contacts.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24.0),
                      child: Center(
                        child: Column(
                          children: const [
                            Icon(Icons.contact_phone_outlined, color: AppColors.onSurfaceVariant, size: 36),
                            SizedBox(height: 8),
                            Text(
                              'No Emergency Contacts Configured',
                              style: TextStyle(fontFamily: 'Inter', color: AppColors.onSurfaceVariant, fontWeight: FontWeight.bold),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Tap "Add Trusted Contact" below to configure contacts.',
                              style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: AppColors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Column(
                      children: List.generate(contactController.contacts.length, (index) {
                        final phone = contactController.contacts[index];
                        final label = 'Contact ${index + 1}';
                        final isLast = index == contactController.contacts.length - 1;
                        return Column(
                          children: [
                            _buildResponderRow(
                              phone,
                              '$label • Notified instantly during SOS',
                              hasPhone: true,
                              onEdit: () => _showEditContactDialog(context, phone),
                            ),
                            if (!isLast) const Divider(color: AppColors.borderSubtle, height: 16),
                          ],
                        );
                      }),
                    ),
            ),
          ),
          const SizedBox(height: 20),

          // Add Trusted Contact Button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: () => _showAddContactDialog(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.safetyGreen,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.person_add_outlined, size: 20),
              label: const Text(
                'Add Trusted Contact',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Community Networks Section
          Row(
            children: const [
              Icon(Icons.hub_outlined, color: AppColors.warningAmber, size: 20),
              SizedBox(width: 8),
              Text(
                'Community Networks',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderSubtle, width: 1),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.apartment_rounded, color: AppColors.onSurfaceVariant, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Oakwood Apartments Watch',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Broadcast SOS alerts to verified neighbors within a 500m radius of your home address.',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 12,
                          color: AppColors.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Switch(
                            value: _isCommunityWatchEnabled,
                            onChanged: (val) => setState(() => _isCommunityWatchEnabled = val),
                            activeThumbColor: AppColors.safetyGreen,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _isCommunityWatchEnabled ? 'Opted In' : 'Opted Out',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _isCommunityWatchEnabled ? AppColors.safetyGreen : AppColors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResponderRow(
    String name,
    String subtitle, {
    required bool hasPhone,
    String? initials,
    Color avatarColor = AppColors.surfaceContainerHigh,
    VoidCallback? onEdit,
  }) {
    return Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: avatarColor,
          child: initials != null
              ? Text(
                  initials,
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                )
              : const Icon(Icons.person, color: AppColors.onSurface, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppColors.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.edit_outlined, color: AppColors.safetyGreen, size: 20),
          onPressed: onEdit,
        ),
      ],
    );
  }

  // --- TAB 4: HISTORY TAB ---
  Widget _buildHistoryTab() {
    final historyController = HistoryController.instanceOrCreate();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Activity Log',
            style: TextStyle(
              fontFamily: 'Manrope',
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Review recent journeys and system events.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),

          // Filter Chips (Scrollable to prevent overflow)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: ['ALL', 'JOURNEYS', 'WARNINGS', 'SOS'].map((filter) {
                final isSelected = _selectedHistoryFilter == filter;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ChoiceChip(
                    label: Text(
                      filter,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isSelected ? Colors.black : AppColors.onSurface,
                      ),
                    ),
                    selected: isSelected,
                    selectedColor: AppColors.safetyGreen,
                    backgroundColor: AppColors.surfaceContainer,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() => _selectedHistoryFilter = filter);
                      }
                    },
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 20),

          // Dynamic History Stream
          Obx(() {
            final allEntries = historyController.entries;
            final filtered = allEntries.where((entry) {
              if (_selectedHistoryFilter == 'ALL') return true;
              if (_selectedHistoryFilter == 'SOS') return entry.type == 'sos';
              if (_selectedHistoryFilter == 'JOURNEYS') return entry.type == 'journey';
              if (_selectedHistoryFilter == 'WARNINGS') return entry.type == 'unsafe' || entry.type == 'warning';
              return true;
            }).toList();

            if (filtered.isEmpty) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Column(
                  children: const [
                    Icon(Icons.history_outlined, size: 48, color: AppColors.onSurfaceVariant),
                    SizedBox(height: 12),
                    Text(
                      'No Real Activity Logs Recorded',
                      style: TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.onSurface),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Real logs will appear here automatically when you start a Journey Guard session or trigger SOS.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
              );
            }

            return ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final entry = filtered[index];
                final isLast = index == filtered.length - 1;

                IconData icon = Icons.info_outline;
                Color iconColor = AppColors.softCyan;
                if (entry.type == 'sos') {
                  icon = Icons.warning_amber_rounded;
                  iconColor = AppColors.signalRed;
                } else if (entry.type == 'journey') {
                  icon = Icons.check_circle_outline;
                  iconColor = AppColors.safetyGreen;
                } else if (entry.type == 'unsafe' || entry.type == 'warning') {
                  icon = Icons.alt_route_rounded;
                  iconColor = AppColors.warningAmber;
                }

                final timeStr = '${entry.timestamp.day}/${entry.timestamp.month}/${entry.timestamp.year} ${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}';

                return _buildHistoryTimelineItem(
                  icon: icon,
                  iconColor: iconColor,
                  title: entry.title,
                  timestamp: timeStr,
                  location: entry.subtitle,
                  isLast: isLast,
                );
              },
            );
          }),
        ],
      ),
    );
  }

  Widget _buildHistoryTimelineItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String timestamp,
    required String location,
    String? badge,
    String? duration,
    bool showMapThumbnail = false,
    bool isLast = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 18),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: showMapThumbnail ? 160 : 70,
                color: AppColors.borderSubtle,
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.borderSubtle, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Manrope',
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      timestamp,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  location,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    color: AppColors.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
                if (badge != null || duration != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (badge != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.primaryContainer.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            badge,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: AppColors.safetyGreen,
                            ),
                          ),
                        ),
                      if (duration != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            duration,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: AppColors.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
                if (showMapThumbnail) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      height: 100,
                      width: double.infinity,
                      color: const Color(0xFF1E293B),
                      child: const Center(
                        child: Icon(Icons.map_outlined, color: Colors.white54, size: 40),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
