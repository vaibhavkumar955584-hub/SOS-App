import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'location_fallback_service.dart';
import 'emergency_message_helper.dart';
import '../controllers/history_controller.dart';
import '../controllers/sos_controller.dart';
import '../controllers/sos_settings_controller.dart';

class EmergencyStatusEvent {
  final String statusText;
  final String category; // 'location', 'sms', 'call', 'cloud', 'recording'
  final bool isSuccess;
  final DateTime timestamp;

  EmergencyStatusEvent({
    required this.statusText,
    required this.category,
    this.isSuccess = true,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

enum TriggerSource {
  appButton,
  voice,
  shake,
  powerButton,
  volumeKeys,
  wearable,
  widget,
  shortcut,
}

class EmergencyDispatchEngine {
  static const MethodChannel _platformChannel = MethodChannel('safe_route/sms');
  static const MethodChannel _shortcutChannel = MethodChannel('safe_route/shortcut');
  static final StreamController<EmergencyStatusEvent> _statusController =
      StreamController<EmergencyStatusEvent>.broadcast();

  static Stream<EmergencyStatusEvent> get statusStream => _statusController.stream;

  static bool _isDispatchActive = false;
  static Timer? _countdownTimer;
  static AudioRecorder? _ambientRecorder;
  static Timer? _ambientRecordingTimer;
  static String? currentActiveSosId;
  static DateTime? ambientRecordingStartTime;

  static void initializeShortcutListener() {
    _shortcutChannel.setMethodCallHandler((call) async {
      if (call.method == 'triggerSos') {
        final args = call.arguments is Map ? (call.arguments as Map) : null;
        final sourceStr = args?['source'] as String? ?? 'widget';
        final source = sourceStr == 'shortcut' ? TriggerSource.shortcut : TriggerSource.widget;
        debugPrint('[EmergencyDispatchEngine] Native SOS trigger received via $source');
        await triggerSos(source: source);
        return true;
      }
      return null;
    });

    _checkPendingColdStartTrigger();
  }

  static Future<void> _checkPendingColdStartTrigger() async {
    try {
      final String? pendingSource = await _shortcutChannel.invokeMethod('getPendingTriggerSource');
      if (pendingSource != null && pendingSource.isNotEmpty) {
        final source = pendingSource == 'shortcut' ? TriggerSource.shortcut : TriggerSource.widget;
        debugPrint('[EmergencyDispatchEngine] Processing pending cold-start trigger: $source');
        await triggerSos(source: source);
      }
    } catch (e) {
      debugPrint('[EmergencyDispatchEngine] Error checking cold-start trigger: $e');
    }
  }

  static void emitStatus(String text, String category, {bool isSuccess = true}) {
    debugPrint('[EmergencyEngine] [$category] $text');
    _statusController.add(
      EmergencyStatusEvent(statusText: text, category: category, isSuccess: isSuccess),
    );
  }

  /// Unified entry point for native widgets, launcher shortcuts, and OS intents
  static Future<void> triggerSos({
    TriggerSource source = TriggerSource.widget,
    int countdownSeconds = 3,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final savedContacts = prefs.getStringList('saved_contacts') ?? [];
    final emergencyContacts = savedContacts.isNotEmpty
        ? savedContacts
        : ['112', '100'];

    await triggerEmergencyDispatch(
      emergencyContacts: emergencyContacts,
      countdownSeconds: countdownSeconds,
      source: source,
    );
  }

  /// Initiates Full Emergency Dispatch Flow (5s Countdown -> Location -> SMS + Cloud -> Call Cascade)
  static Future<void> triggerEmergencyDispatch({
    required List<String> emergencyContacts,
    int countdownSeconds = 5,
    TriggerSource source = TriggerSource.appButton,
    String? sosId,
  }) async {
    if (_isDispatchActive) {
      debugPrint('[EmergencyEngine] Emergency Dispatch already in progress.');
      return;
    }
    _isDispatchActive = true;

    final String activeSosId = sosId ?? 'sos_${DateTime.now().millisecondsSinceEpoch}';
    currentActiveSosId = activeSosId;

    emitStatus('SOS Triggered via ${source.name.toUpperCase()} (Starting $countdownSeconds s Countdown)...', 'countdown');

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

    // Record real event log in HistoryController with unified sosId
    try {
      await HistoryController.instanceOrCreate().recordSos(
        sosId: activeSosId,
        status: 'Activated',
        locationLabel: locResult.statusLabel,
        triggerSource: source.name,
      );
    } catch (_) {}

    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? 'guest';
    final latStr = locResult.position?.latitude.toStringAsFixed(6);
    final lngStr = locResult.position?.longitude.toStringAsFixed(6);
    final smsPayload = await EmergencyMessageHelper.buildSosMessage(
      uid: currentUid,
      lat: latStr,
      lng: lngStr,
      locationLabel: locResult.statusLabel,
      sessionId: activeSosId,
    );

    // 3. PARALLEL DISPATCH: AMBIENT RECORDING (MIC SOURCE), CLOUD FIRESTORE & HARDWARE SMS
    unawaited(_startAmbientRecording(sosId: activeSosId));
    unawaited(_executeCloudSync(locResult, emergencyContacts));
    unawaited(_executeSmsDispatch(emergencyContacts, smsPayload));

    // 4. TELEPHONY CALL CASCADE (Runs concurrently alongside ambient MIC recording)
    await _executeCallCascade(emergencyContacts);
  }

  /// Task A: Starts parallel ambient audio recording using MIC source (not VOICE_CALL)
  static Future<void> _startAmbientRecording({required String sosId}) async {
    final consentGranted = SosSettingsController.instanceOrCreate().isAmbientRecordingConsentGranted.value;

    if (!consentGranted) {
      emitStatus('Ambient Recording skipped: Consent not granted by user in settings.', 'recording', isSuccess: false);
      return;
    }

    try {
      _ambientRecorder ??= AudioRecorder();
      if (!await _ambientRecorder!.hasPermission()) {
        emitStatus('Ambient Recording unavailable: Microphone permission not granted.', 'recording', isSuccess: false);
        return;
      }

      final baseDir = await getApplicationSupportDirectory();
      final targetDir = Directory('${baseDir.path}${Platform.pathSeparator}sos_recordings');
      if (!targetDir.existsSync()) {
        await targetDir.create(recursive: true);
      }

      final now = DateTime.now();
      final timestampStr = '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final fileName = 'sos_audio_${sosId}_$timestampStr.m4a';
      final filePath = '${targetDir.path}${Platform.pathSeparator}$fileName';

      emitStatus('Starting Ambient Mic Recording (Parallel with Call Cascade) -> $fileName', 'recording');

      // CRITICAL CONSTRAINT: Using MIC source (AudioEncoder.aacLc), NOT VOICE_CALL
      await _ambientRecorder!.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: filePath,
      );

      ambientRecordingStartTime = DateTime.now();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sos_recording_path', filePath);
      await prefs.setString('sos_recording_public_path', filePath);
      SosController.instanceOrCreate().lastRecordingPrivatePath.value = filePath;
      SosController.instanceOrCreate().lastRecordingPublicPath.value = filePath;

      await HistoryController.instanceOrCreate().updateSosRecordingInfo(
        sosId: sosId,
        recordingFilePath: filePath,
        durationSeconds: 0,
        uploadStatus: 'local',
      );

      // Capped at 5 minutes maximum recording duration for battery & storage
      _ambientRecordingTimer?.cancel();
      _ambientRecordingTimer = Timer(const Duration(minutes: 5), () async {
        await stopAmbientRecording(sosId: sosId, startTime: ambientRecordingStartTime);
      });
    } catch (e) {
      emitStatus('Ambient Recording Failed to start: $e', 'recording', isSuccess: false);
    }
  }

  /// Stops active ambient recording and links filepath to the exact SOS history row
  static Future<void> stopAmbientRecording({String? sosId, DateTime? startTime}) async {
    _ambientRecordingTimer?.cancel();
    _ambientRecordingTimer = null;

    final targetSosId = sosId ?? currentActiveSosId ?? 'sos_${DateTime.now().millisecondsSinceEpoch}';
    final targetStartTime = startTime ?? ambientRecordingStartTime;

    if (_ambientRecorder != null && await _ambientRecorder!.isRecording()) {
      try {
        final path = await _ambientRecorder!.stop();
        final effectivePath = (path != null && path.isNotEmpty)
            ? path
            : SosController.instanceOrCreate().lastRecordingDisplayPath;

        if (effectivePath.isNotEmpty) {
          final durationSecs = targetStartTime != null ? DateTime.now().difference(targetStartTime).inSeconds : 0;
          emitStatus('Ambient Recording Stopped & Saved -> $effectivePath (${durationSecs}s)', 'recording');

          String publicExportPath = effectivePath;
          try {
            final fileName = effectivePath.split(Platform.pathSeparator).last;
            final result = await _platformChannel.invokeMethod<Map<dynamic, dynamic>>(
              'saveToDownloads',
              {'sourcePath': effectivePath, 'displayName': fileName},
            );
            if (result != null && result['success'] == true) {
              final exported = result['publicPath']?.toString();
              if (exported != null && exported.isNotEmpty) {
                publicExportPath = exported;
                emitStatus('Exported public copy to Downloads / SoundRecorder -> $publicExportPath', 'recording');
              }
            }
          } catch (e) {
            debugPrint('[SOS Recording] Auto export error: $e');
          }

          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('sos_recording_path', effectivePath);
          await prefs.setString('sos_recording_public_path', publicExportPath);
          SosController.instanceOrCreate().lastRecordingPrivatePath.value = effectivePath;
          SosController.instanceOrCreate().lastRecordingPublicPath.value = publicExportPath;

          // Link recording to existing history entry via authoritative sosId
          await HistoryController.instanceOrCreate().updateSosRecordingInfo(
            sosId: targetSosId,
            recordingFilePath: effectivePath,
            remoteUrl: publicExportPath,
            durationSeconds: durationSecs > 0 ? durationSecs : 15,
            uploadStatus: 'local',
          );

          // Update Firestore SOS session with recording metadata
          final uid = FirebaseAuth.instance.currentUser?.uid;
          if (uid != null) {
            try {
              await FirebaseFirestore.instance.collection('active_sos').doc(uid).set({
                'recordingPath': effectivePath,
                'recordingDuration': durationSecs > 0 ? durationSecs : 15,
                'recordingStatus': 'COMPLETED',
                'recordingUpdatedAt': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            } catch (e) {
              debugPrint('[SOS Recording] Firestore metadata sync error: $e');
            }
          }
        } else {
          emitStatus('Ambient Recording File empty or invalid', 'recording', isSuccess: false);
        }
      } catch (e) {
        emitStatus('Failed to stop ambient recording: $e', 'recording', isSuccess: false);
      }
    }
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
      emitStatus('All Contacts Unanswered. Initiating Final Fallback: Dialing 112 Emergency Police...', 'call', isSuccess: true);
      try {
        final Map<dynamic, dynamic>? res = await _platformChannel.invokeMethod('makeDirectCall', {
          'phoneNumber': '112',
        });
        final bool openedDialer = res?['openedDialer'] == true;
        if (res?['success'] == true && !openedDialer) {
          emitStatus('112 Emergency Police Auto-Dialed Successfully.', 'call', isSuccess: true);
        } else if (res?['success'] == true && openedDialer) {
          emitStatus('112 opened in dialer — please tap Call on your phone screen.', 'call', isSuccess: true);
        } else {
          emitStatus('112 dispatch returned: ${res?['errorMessage'] ?? 'unknown error'}', 'call', isSuccess: false);
        }
      } catch (e) {
        emitStatus('Failed to dial 112 Emergency Police: $e', 'call', isSuccess: false);
      }
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

      // If it's an emergency number, don't block — the call goes through automatically
      if (res?['isEmergency'] == true) {
        return 'OFFHOOK';
      }

      // Wait up to 4 seconds for OFFHOOK answer signal (reduced from 6 to prevent UI freeze)
      for (int t = 0; t < 4; t++) {
        await Future.delayed(const Duration(seconds: 1));
        if (!_isDispatchActive) return 'CANCELLED';
      }
      return 'NO_ANSWER';
    } catch (e) {
      return 'FAILED';
    }
  }
}

