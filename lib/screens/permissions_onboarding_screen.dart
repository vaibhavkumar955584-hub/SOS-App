import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:get/get.dart';
import '../theme/app_colors.dart';
import 'main_shell_screen.dart';

class PermissionsOnboardingScreen extends StatefulWidget {
  const PermissionsOnboardingScreen({super.key});

  @override
  State<PermissionsOnboardingScreen> createState() => _PermissionsOnboardingScreenState();
}

class _PermissionsOnboardingScreenState extends State<PermissionsOnboardingScreen> {
  final Map<Permission, bool> _permissionStatuses = {
    Permission.location: false,
    Permission.phone: false,
    Permission.sms: false,
    Permission.contacts: false,
    Permission.microphone: false,
    Permission.notification: false,
  };

  bool _isRequesting = false;

  @override
  void initState() {
    super.initState();
    _checkCurrentPermissions();
  }

  Future<void> _checkCurrentPermissions() async {
    for (final permission in _permissionStatuses.keys) {
      final status = await permission.status;
      _permissionStatuses[permission] = status.isGranted;
    }
    if (mounted) setState(() {});
  }

  Future<void> _requestAllPermissions() async {
    setState(() => _isRequesting = true);

    final permissionsToRequest = [
      Permission.locationWhenInUse,
      Permission.locationAlways,
      Permission.phone,
      Permission.sms,
      Permission.contacts,
      Permission.microphone,
      Permission.notification,
      Permission.ignoreBatteryOptimizations,
    ];

    for (final permission in permissionsToRequest) {
      final status = await permission.request();
      debugPrint('[PermissionFlow] ${permission.toString()}: ${status.toString()}');
    }

    await _checkCurrentPermissions();
    setState(() => _isRequesting = false);

    final allEssentialGranted = (_permissionStatuses[Permission.location] ?? false) &&
        (_permissionStatuses[Permission.phone] ?? false) &&
        (_permissionStatuses[Permission.sms] ?? false);

    if (allEssentialGranted) {
      Get.offAll(() => const MainShellScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Safety Permissions',
          style: TextStyle(
            fontFamily: 'Manrope',
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppColors.onSurface,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Required for Life Safety Operations',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: AppColors.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'SafeRoute requires essential hardware permissions to trigger automatic emergency dispatch, GPS rerouting, and silent SOS calls.',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  color: AppColors.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),

              Expanded(
                child: ListView(
                  children: [
                    _buildPermissionTile(
                      icon: Icons.location_on_outlined,
                      title: 'High-Precision GPS & Location',
                      rationale: 'Used for danger-zone rerouting and embedding coordinates in SOS emergency alerts.',
                      isGranted: _permissionStatuses[Permission.location] ?? false,
                    ),
                    _buildPermissionTile(
                      icon: Icons.phone_in_talk_outlined,
                      title: 'Direct Telephony Call (CALL_PHONE)',
                      rationale: 'Enables instant hands-free phone calls to emergency contacts and emergency services (112).',
                      isGranted: _permissionStatuses[Permission.phone] ?? false,
                    ),
                    _buildPermissionTile(
                      icon: Icons.sms_outlined,
                      title: 'Direct Hardware SMS (SEND_SMS)',
                      rationale: 'Dispatches emergency SMS alerts directly via SIM hardware even without internet data.',
                      isGranted: _permissionStatuses[Permission.sms] ?? false,
                    ),
                    _buildPermissionTile(
                      icon: Icons.mic_none_outlined,
                      title: 'Microphone & Voice Wake-Word',
                      rationale: 'Powers hands-free voice keyword detection ("Help me now") and emergency recording.',
                      isGranted: _permissionStatuses[Permission.microphone] ?? false,
                    ),
                    _buildPermissionTile(
                      icon: Icons.notifications_none_outlined,
                      title: 'Foreground Notifications',
                      rationale: 'Displays persistent background safety monitoring status required for hardware sensor triggers.',
                      isGranted: _permissionStatuses[Permission.notification] ?? false,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _isRequesting ? null : _requestAllPermissions,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.safetyGreen,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: _isRequesting
                      ? const CircularProgressIndicator(color: Colors.black)
                      : const Text(
                          'Grant Safety Permissions',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionTile({
    required IconData icon,
    required String title,
    required String rationale,
    required bool isGranted,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isGranted ? AppColors.primaryContainer.withValues(alpha: 0.2) : AppColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: isGranted ? AppColors.safetyGreen : AppColors.onSurfaceVariant, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.onSurface,
                        ),
                      ),
                    ),
                    Icon(
                      isGranted ? Icons.check_circle : Icons.circle_outlined,
                      color: isGranted ? AppColors.safetyGreen : AppColors.onSurfaceVariant,
                      size: 18,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  rationale,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: AppColors.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
