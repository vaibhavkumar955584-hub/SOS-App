import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/sos_controller.dart';
import '../controllers/contact_controller.dart';
import '../services/emergency_dispatch_engine.dart';
import '../theme/app_colors.dart';

class EmergencySosScreen extends StatefulWidget {
  const EmergencySosScreen({super.key});

  @override
  State<EmergencySosScreen> createState() => _EmergencySosScreenState();
}

class _EmergencySosScreenState extends State<EmergencySosScreen> {
  final SosController sosController = Get.find<SosController>();
  final ContactController contactController = ContactController.instanceOrCreate();

  late Timer _timer;
  StreamSubscription<EmergencyStatusEvent>? _statusSub;
  int _secondsElapsed = 0;
  int _cancelCountdown = 5;

  final List<EmergencyStatusEvent> _liveEvents = [];
  String _latestLocationStatus = 'Resolving Location...';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _secondsElapsed++;
          if (_cancelCountdown > 0) {
            _cancelCountdown--;
          }
        });
      }
    });

    _statusSub = EmergencyDispatchEngine.statusStream.listen((event) {
      if (mounted) {
        setState(() {
          _liveEvents.insert(0, event);
          if (event.category == 'location') {
            _latestLocationStatus = event.statusText;
          }
        });
      }
    });

    // Start Emergency Dispatch Workflow
    final contacts = contactController.contacts.toList();
    EmergencyDispatchEngine.triggerEmergencyDispatch(
      emergencyContacts: contacts.isNotEmpty ? contacts : ['911', '112'],
      countdownSeconds: 5,
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  String _formatDuration(int seconds) {
    final mins = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  void _showCancelPinDialog(BuildContext context) {
    final pinController = TextEditingController();

    Get.dialog(
      AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Enter Safety PIN to Cancel', style: TextStyle(color: AppColors.onSurface, fontFamily: 'Manrope', fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter your 4-digit PIN to disarm the emergency broadcast.',
              style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 4,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 8, color: AppColors.onSurface, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                hintText: '••••',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('Dismiss', style: TextStyle(color: AppColors.onSurfaceVariant)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.safetyGreen, foregroundColor: Colors.black),
            onPressed: () {
              final pin = pinController.text.trim();
              Get.back();
              if (pin == '9999') {
                // Duress PIN entered: Silent distress alert!
                Get.snackbar(
                  'Silent Distress Alert',
                  'Duress panic signal sent to emergency network.',
                  snackPosition: SnackPosition.TOP,
                  backgroundColor: Colors.purpleAccent,
                  colorText: Colors.white,
                );
                final contacts = contactController.contacts.toList();
                EmergencyDispatchEngine.triggerEmergencyDispatch(
                  emergencyContacts: contacts.isNotEmpty ? contacts : ['911', '112'],
                  countdownSeconds: 0,
                );
              } else {
                // Normal disarm PIN entered
                EmergencyDispatchEngine.cancelEmergencyDispatch();
                sosController.cancelSOS();
                Navigator.maybePop(context);
              }
            },
            child: const Text('Confirm PIN'),
          ),
        ],
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
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: AppColors.onSurface, size: 20),
          onPressed: () => Navigator.maybePop(context),
        ),
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: AppColors.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.shield, color: Colors.black, size: 10),
            ),
            const SizedBox(width: 8),
            const Text(
              'EMERGENCY SOS',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppColors.onSurface,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      // 1. SOS HEADER ALERT CONTAINER
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFB9000D), Color(0xFF7F0000)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.signalRed.withValues(alpha: 0.4),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: const BoxDecoration(
                                      color: Colors.redAccent,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  const Text(
                                    'ACTIVE EMERGENCY DISPATCH',
                                    style: TextStyle(
                                      fontFamily: 'Inter',
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              _formatDuration(_secondsElapsed),
                              style: const TextStyle(
                                fontFamily: 'Manrope',
                                fontSize: 48,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                letterSpacing: -1,
                              ),
                            ),
                            const Text(
                              'Time since activation',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 13,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // 2. LIVE LOCATION SHARED CARD
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainer,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.borderSubtle, width: 1),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: const BoxDecoration(
                                  color: AppColors.surfaceContainerHigh,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.my_location, color: AppColors.safetyGreen, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'GPS Live Broadcast',
                                      style: TextStyle(
                                        fontFamily: 'Manrope',
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _latestLocationStatus,
                                      style: const TextStyle(
                                        fontFamily: 'Inter',
                                        fontSize: 11,
                                        color: AppColors.onSurfaceVariant,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // 3. LIVE EVENT LOG STREAM
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
                            Row(
                              children: const [
                                Icon(Icons.receipt_long_outlined, color: AppColors.onSurfaceVariant, size: 18),
                                SizedBox(width: 8),
                                Text(
                                  'REAL-TIME DISPATCH LOGS',
                                  style: TextStyle(
                                    fontFamily: 'Inter',
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.onSurfaceVariant,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (_liveEvents.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'Initiating multi-tier emergency dispatch engine...',
                                  style: TextStyle(fontFamily: 'Inter', fontSize: 12, color: AppColors.onSurfaceVariant),
                                ),
                              )
                            else
                              ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _liveEvents.length > 5 ? 5 : _liveEvents.length,
                                separatorBuilder: (_, __) => const Divider(color: AppColors.borderSubtle, height: 12),
                                itemBuilder: (context, index) {
                                  final event = _liveEvents[index];
                                  return Row(
                                    children: [
                                      Icon(
                                        event.isSuccess ? Icons.check_circle_outline : Icons.pending_outlined,
                                        color: event.isSuccess ? AppColors.safetyGreen : AppColors.softCyan,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          event.statusText,
                                          style: const TextStyle(fontFamily: 'Inter', fontSize: 12, color: AppColors.onSurface),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),

              // 4. CANCEL SOS BUTTON
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: () {
                    _showCancelPinDialog(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.surfaceContainerHigh,
                    foregroundColor: AppColors.onSurface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                      side: const BorderSide(color: AppColors.borderSubtle, width: 1),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.cancel_outlined, color: AppColors.onSurfaceVariant, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        _cancelCountdown > 0
                            ? 'CANCEL SOS ( ${_cancelCountdown.toString().padLeft(2, ' ')} s)'
                            : 'CANCEL EMERGENCY SOS',
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
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
    );
  }
}
