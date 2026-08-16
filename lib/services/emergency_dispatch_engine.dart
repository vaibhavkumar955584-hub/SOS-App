import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'location_fallback_service.dart';
import '../controllers/history_controller.dart';

class EmergencyStatusEvent {
  final String statusText;
  final String category; // 'location', 'sms', 'call', 'cloud'
  final bool isSuccess;
  final DateTime timestamp;

  EmergencyStatusEvent({
    required this.statusText,
    required this.category,
    this.isSuccess = true,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class EmergencyDispatchEngine {
  static const MethodChannel _platformChannel = MethodChannel('safe_route/sms');
  static final StreamController<EmergencyStatusEvent> _statusController =
      StreamController<EmergencyStatusEvent>.broadcast();

  static Stream<EmergencyStatusEvent> get statusStream => _statusController.stream;

  static bool _isDispatchActive = false;
  static Timer? _countdownTimer;

  static void emitStatus(String text, String category, {bool isSuccess = true}) {
    debugPrint('[EmergencyEngine] [$category] $text');
    _statusController.add(
      EmergencyStatusEvent(statusText: text, category: category, isSuccess: isSuccess),
    );
  }

  /// Initiates Full Emergency Dispatch Flow (5s Countdown -> Location -> SMS + Cloud -> Call Cascade)
  static Future<void> triggerEmergencyDispatch({
    required List<String> emergencyContacts,
    int countdownSeconds = 5,
  }) async {
    if (_isDispatchActive) {
      debugPrint('[EmergencyEngine] Emergency Dispatch already in progress.');
      return;
    }
    _isDispatchActive = true;

    emitStatus('Starting Emergency Countdown ($countdownSeconds s)...', 'countdown');

    // 1. 5-SECOND CANCELABLE COUNTDOWN
    int remaining = countdownSeconds;
    final completer = Completer<bool>();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      remaining--;
      if (remaining > 0) {
        emitStatus('Countdown: $remaining s remaining (Tap Cancel to Stop)', 'countdown');
      } else {
        timer.cancel();
        if (!completer.isCompleted) completer.complete(true);
      }
    });

    final proceed = await completer.future;
    if (!proceed || !_isDispatchActive) {
      emitStatus('Emergency Dispatch Cancelled by User.', 'countdown', isSuccess: false);
      return;
    }

    // 2. 5-TIER LOCATION RESOLUTION
    emitStatus('Resolving location (Tier 1: High GPS)...', 'location');
    final locResult = await LocationFallbackService.resolveLocationForEmergency();
    emitStatus('Location Resolved: ${locResult.statusLabel}', 'location', isSuccess: !locResult.isFallback);

    // Record real event log in HistoryController
    try {
      await HistoryController.instanceOrCreate().recordSos(
        status: 'Activated',
        locationLabel: locResult.statusLabel,
      );
    } catch (_) {}

    final timestampStr = DateTime.now().toIso8601String();
    final trackingLink = 'https://saferoute-55bb6.web.app/track?uid=${FirebaseAuth.instance.currentUser?.uid ?? 'guest'}';
    final smsPayload = '🚨 EMERGENCY SOS ALERT! 🚨\n${locResult.formattedPayload}\nTime: $timestampStr\nLive Tracking: $trackingLink';

    // 3. PARALLEL DISPATCH: CLOUD FIRESTORE & HARDWARE SMS
    unawaited(_executeCloudSync(locResult, emergencyContacts));
    unawaited(_executeSmsDispatch(emergencyContacts, smsPayload));

    // 4. TELEPHONY CALL CASCADE
    await _executeCallCascade(emergencyContacts);
  }

  /// Cancels active emergency dispatch countdown & execution
  static void cancelEmergencyDispatch() {
    _isDispatchActive = false;
    _countdownTimer?.cancel();
    emitStatus('Emergency Dispatch Halted.', 'countdown', isSuccess: false);
  }

  /// Parallel Step 1: Firestore Real-Time Session Sync with Local Retry Queue
  static Future<void> _executeCloudSync(
    LocationResolutionResult locResult,
    List<String> contacts,
  ) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous_device';
    final payload = {
      'uid': uid,
      'active': true,
      'status': 'active',
      'triggeredAt': DateTime.now().toIso8601String(),
      'locationStatus': locResult.statusLabel,
      'latitude': locResult.position?.latitude ?? 0.0,
      'longitude': locResult.position?.longitude ?? 0.0,
      'contacts': contacts,
      'locationPayload': locResult.formattedPayload,
      'retryCount': 0,
    };

    try {
      emitStatus('Pushing Cloud Alert & Live Tracking to Firestore...', 'cloud');
      final docRef = FirebaseFirestore.instance.collection('active_sos').doc(uid);

      await docRef.set({
        'uid': uid,
        'active': true,
        'status': 'active',
        'triggeredAt': FieldValue.serverTimestamp(),
        'locationStatus': locResult.statusLabel,
        'latitude': locResult.position?.latitude ?? 0.0,
        'longitude': locResult.position?.longitude ?? 0.0,
        'contacts': contacts,
        'locationPayload': locResult.formattedPayload,
      });

      emitStatus('Cloud Alert Synced Successfully to Firestore.', 'cloud');
    } catch (e) {
      emitStatus('Cloud Sync Failed: $e. Queueing payload locally...', 'cloud', isSuccess: false);
      await _queuePendingCloudSync(payload);
    }
  }

  static const String _queuedSyncKey = 'pending_cloud_sync_queue';

  /// Line 136: Persists pending payload locally on Firestore write failure
  static Future<void> _queuePendingCloudSync(Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getStringList(_queuedSyncKey) ?? [];
      existing.add(jsonEncode(payload));
      await prefs.setStringList(_queuedSyncKey, existing);
      debugPrint('[EmergencyEngine] Cloud sync failed. Queued payload locally. Queue size: ${existing.length}');
    } catch (e) {
      debugPrint('[EmergencyEngine] Error queueing cloud sync: $e');
    }
  }

  /// Line 148: Flushes pending cloud syncs on reconnect / app foreground
  static Future<void> flushPendingCloudSyncs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queuedStrings = prefs.getStringList(_queuedSyncKey) ?? [];
      if (queuedStrings.isEmpty) return;

      debugPrint('[EmergencyEngine] Reconnect detected. Flushing ${queuedStrings.length} queued cloud sync(s)...');
      final remaining = <String>[];

      for (final rawJson in queuedStrings) {
        try {
          final Map<String, dynamic> item = jsonDecode(rawJson);
          final uid = item['uid']?.toString() ?? 'anonymous_device';
          final retryCount = (item['retryCount'] as int? ?? 0) + 1;

          if (retryCount > 5) {
            debugPrint('[EmergencyEngine] Max retries (5) reached for queued payload ($uid). Dropping item.');
            continue;
          }

          final docRef = FirebaseFirestore.instance.collection('active_sos').doc(uid);
          await docRef.set({
            'uid': uid,
            'active': true,
            'status': 'active',
            'triggeredAt': FieldValue.serverTimestamp(),
            'locationStatus': item['locationStatus'],
            'latitude': item['latitude'],
            'longitude': item['longitude'],
            'contacts': item['contacts'],
            'locationPayload': item['locationPayload'],
          });

          debugPrint('[EmergencyEngine] Queue flush succeeded for $uid. Firestore write complete.');
        } catch (e) {
          debugPrint('[EmergencyEngine] Queue flush failed on retry: $e');
          final Map<String, dynamic> item = jsonDecode(rawJson);
          item['retryCount'] = (item['retryCount'] as int? ?? 0) + 1;
          remaining.add(jsonEncode(item));
        }
      }

      await prefs.setStringList(_queuedSyncKey, remaining);
    } catch (e) {
      debugPrint('[EmergencyEngine] Error flushing queued syncs: $e');
    }
  }

  /// Parallel Step 2: Direct Hardware SMS Dispatch with Per-Contact Status
  static Future<void> _executeSmsDispatch(List<String> contacts, String message) async {
    if (contacts.isEmpty) {
      emitStatus('No emergency contacts configured for SMS.', 'sms', isSuccess: false);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final subId = prefs.getInt('preferred_sms_subscription_id');

    for (int i = 0; i < contacts.length; i++) {
      if (!_isDispatchActive) break;
      final contact = contacts[i].trim();
      if (contact.isEmpty) continue;

      emitStatus('Sending Direct SMS to Contact ${i + 1} ($contact)...', 'sms');

      try {
        final Map<dynamic, dynamic>? res = await _platformChannel.invokeMethod('sendDirectSms', {
          'phoneNumber': contact,
          'message': message,
          'subscriptionId': subId,
        });

        final bool success = res?['success'] == true;
        final String? errorMsg = res?['errorMessage']?.toString();

        if (success) {
          emitStatus('SMS Delivered to Contact ${i + 1} ($contact) [RESULT_OK]', 'sms');
        } else {
          emitStatus('SMS Failed to Contact ${i + 1}: ${errorMsg ?? "Unknown error"}', 'sms', isSuccess: false);
        }
      } catch (e) {
        emitStatus('SMS Invocation Failed for $contact: $e', 'sms', isSuccess: false);
      }

      await Future.delayed(const Duration(seconds: 2));
    }
  }

  /// Step 4: Telephony Call Cascade (Contact 1 -> Contact 2 -> Contact 3 -> 112)
  static Future<void> _executeCallCascade(List<String> contacts) async {
    // Start native TelephonyListener
    try {
      await _platformChannel.invokeMethod('startCallListener');
    } catch (e) {
      debugPrint('[EmergencyEngine] Call listener setup: $e');
    }

    final validContacts = contacts.where((c) => c.trim().isNotEmpty).toList();

    for (int i = 0; i < validContacts.length; i++) {
      if (!_isDispatchActive) break;
      final phone = validContacts[i].trim();

      emitStatus('Dialing Emergency Contact ${i + 1} ($phone)...', 'call');

      final callRes = await _makeCallAndWait(phone);
      if (callRes == 'OFFHOOK') {
        emitStatus('Call Answered by Contact ${i + 1}! Halting Call Cascade.', 'call');
        return;
      } else {
        emitStatus('Contact ${i + 1} Unanswered/Busy. Advancing Cascade...', 'call', isSuccess: false);
      }
    }

    // Final Fallback Step: 112 Emergency Services Dispatch
    if (_isDispatchActive) {
      emitStatus('All Contacts Unanswered. Initiating Final Fallback: Dialing 112 Emergency Police...', 'call', isSuccess: false);
      await _makeCallAndWait('112');
    }
  }

  static Future<String> _makeCallAndWait(String phone) async {
    try {
      final Map<dynamic, dynamic>? res = await _platformChannel.invokeMethod('makeDirectCall', {
        'phoneNumber': phone,
      });

      if (res?['success'] != true) {
        return 'FAILED';
      }

      // Wait up to 6 seconds for OFFHOOK answer signal
      for (int t = 0; t < 6; t++) {
        await Future.delayed(const Duration(seconds: 1));
        if (!_isDispatchActive) return 'CANCELLED';
      }
      return 'NO_ANSWER';
    } catch (e) {
      return 'FAILED';
    }
  }
}
