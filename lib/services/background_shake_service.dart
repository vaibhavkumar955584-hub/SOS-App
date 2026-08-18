import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'emergency_message_helper.dart';
import '../controllers/history_controller.dart';
import '../firebase_options.dart';

const double _strongShakeMagnitudeThreshold = 26.5;
const double _axisDirectionThreshold = 16.0;
const double _violentSnatchMagnitudeThreshold = 36.0;
const int _requiredStrongOscillations = 4;
const int _shakeSequenceWindowMs = 1700;
const int _minShakeGapMs = 90;
const int _maxShakeGapMs = 600;
const int _sosCooldownMs = 10000;
const int _cancelCountdownSeconds = 3;
const int _voiceSosCooldownMs = 15000;
const int _voiceCountdownSeconds = 5;
const Duration _recordingMaxDuration = Duration(minutes: 10);
const String _backgroundServiceNotificationChannelId = 'safe_route_sos_channel';
const String _shakeSosEnabledPrefsKey = 'is_shake_active';
const String _voiceSosEnabledPrefsKey = 'is_voice_sos_active';
const String _recordingActivePrefsKey = 'sos_recording_active';
const String _recordingSessionPrefsKey = 'sos_recording_session_id';
const String _recordingPathPrefsKey = 'sos_recording_path';
const String _recordingFileNamePrefsKey = 'sos_recording_file_name';
const String _recordingPartPrefsKey = 'sos_recording_part_number';
const String _recordingPublicPathPrefsKey = 'sos_recording_public_path';
const String _recordingStartedAtPrefsKey = 'sos_recording_started_at';
const String _recordingStatusPrefsKey = 'sos_recording_status';
const String _voiceStatusPrefsKey = 'voice_sos_status';
const String _preferredSmsSubscriptionPrefsKey =
    'preferred_sms_subscription_id';
const String _sosPendingOwnerPrefsKey = 'sos_pending_owner';
const String _sosStatePrefsKey = 'is_sos_active';
const MethodChannel _platformChannel = MethodChannel('safe_route/sms');

bool matchesEmergencyVoicePhrase(String spokenWords) {
  if (spokenWords.trim().isEmpty) {
    return false;
  }

  // Preserve Unicode letters, marks (vowel signs/matras), numbers and whitespace
  final normalized = spokenWords
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}\s]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  if (normalized.isEmpty) {
    return false;
  }

  const triggerPhrases = [
    // English keywords & variations
    'help me please',
    'please help me',
    'please help',
    'help please',
    'help me',
    'help us',
    'help',
    'save me',
    'save us',
    'save',
    'sos',
    'emergency',
    'medical emergency',
    'danger',
    'police',
    'call police',
    'stop',
    'attack',
    'someone help',
    'i need help',
    'need help',

    // Hinglish keywords & phonetic variations
    'bachao mujhe',
    'mujhe bachao',
    'bachao bachao',
    'koi bachao',
    'bhai bachao',
    'bachao',
    'bchao',
    'madad karo',
    'meri madad karo',
    'madad',
    'police bulao',
    'khatra',
    'chhedkhani',
    'raksha karo',
    'sahayata karo',
    'sahayata',
    'jaan bachao',

    // Hindi (Devanagari) keywords
    'मुझे बचाओ',
    'बचाओ मुझे',
    'बचाओ बचाओ',
    'कोई बचाओ',
    'बचाओ',
    'मदद करो',
    'मेरी मदद करो',
    'मदद',
    'सहायता',
    'हेल्प मी',
    'प्लीज हेल्प',
    'हेल्प',
    'पुलिस बुलाओ',
    'पुलिस',
    'इमरजेंसी',
    'खतरा',
    'हमला',
    'रोको',
    'जान बचाओ',
  ];

  // 1. Check direct phrase match
  for (final phrase in triggerPhrases) {
    if (normalized.contains(phrase)) {
      return true;
    }
  }

  // 2. Token / single-word matching
  final words = normalized.split(' ');
  for (final word in words) {
    if (triggerPhrases.contains(word)) {
      return true;
    }
  }

  return false;
}

String buildSosRecordingFileName(
  String sessionId,
  int partNumber,
  DateTime now,
) {
  final compactTimestamp =
      '${now.year.toString().padLeft(4, '0')}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}_'
      '${now.hour.toString().padLeft(2, '0')}'
      '${now.minute.toString().padLeft(2, '0')}'
      '${now.second.toString().padLeft(2, '0')}';
  return 'sos_audio_${sessionId}_part_${partNumber}_$compactTimestamp.m4a';
}

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'safe_route_sos_channel',
    'VIGIL SOS Service',
    description:
        'Actively monitors hardware sensors for SOS shakes even when locked.',
    importance: Importance.high,
  );

  const AndroidNotificationChannel wakeChannel = AndroidNotificationChannel(
    'sos_wake_channel_v1',
    'SOS Critical Wake Lock',
    description: 'Wakes the screen when shaking is detected natively',
    importance: Importance.max,
  );

  const AndroidNotificationChannel nearbyChannel = AndroidNotificationChannel(
    'sos_nearby_channel_v1',
    'Nearby SOS Alerts',
    description:
        'Alerts you instantly when a user triggers an emergency nearby.',
    importance: Importance.max,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(wakeChannel);

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(nearbyChannel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      autoStartOnBoot: false,
      isForegroundMode: true,
      notificationChannelId: _backgroundServiceNotificationChannelId,
      initialNotificationTitle: 'VIGIL Active',
      initialNotificationContent: 'Monitoring hardware shakes for emergencies.',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: const [
        AndroidForegroundType.location,
        AndroidForegroundType.microphone,
        AndroidForegroundType.specialUse,
      ],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint("Firebase already initialized or failed: $e");
  }

  final List<String> notifiedSosList = [];
  final prefs = await SharedPreferences.getInstance();
  final detector = EmergencyShakeDetector();
  final speechToText = SpeechToText();
  final recorder = AudioRecorder();
  final androidService = service is AndroidServiceInstance ? service : null;

  bool isCountdownActive = false;
  bool isListening = false;
  bool isRecording = false;
  bool isSpeechToTextInitialized = false;
  int voiceRestartCount = 0;
  String lastVoiceTranscript = '';
  String lastVoiceError = 'NONE';
  String currentVoiceState = 'IDLE';
  var isShakeEnabled = prefs.getBool(_shakeSosEnabledPrefsKey) ?? false;
  DateTime? lastVoiceTriggerAt;
  StreamSubscription<UserAccelerometerEvent>? accelerometerSubscription;
  Timer? recordingTimeoutTimer;

  Future<void> updateServiceNotification({
    required String title,
    required String content,
  }) async {
    if (androidService != null) {
      await androidService.setAsForegroundService();
      await androidService.setForegroundNotificationInfo(
        title: title,
        content: content,
      );
    }
  }

  String idleMonitoringContent() {
    final voiceEnabled = prefs.getBool(_voiceSosEnabledPrefsKey) ?? false;
    if (voiceEnabled && isShakeEnabled) {
      return 'Listening for voice SOS and monitoring hardware shakes.';
    }
    if (voiceEnabled) {
      return 'Listening for voice SOS in the background.';
    }
    if (isShakeEnabled) {
      return 'Monitoring hardware shake gestures in background.';
    }
    return 'VIGIL background safety service active.';
  }

  Future<void> emitVoiceStatus(
    String status, {
    bool isActive = false,
    String? detail,
  }) async {
    await prefs.setString(_voiceStatusPrefsKey, status);
    service.invoke('voice_sos_status', {
      'status': status,
      'isActive': isActive,
      'detail': detail,
      'state': currentVoiceState,
      'lastTranscript': lastVoiceTranscript,
      'restartCount': voiceRestartCount,
      'lastError': lastVoiceError,
    });
    debugPrint('[Voice SOS] [$currentVoiceState] $status${detail == null ? '' : ' - $detail'} (restarts: $voiceRestartCount)');
  }

  Future<void> emitRecordingStatus(
    String status, {
    bool isActive = false,
    String? path,
    String? publicPath,
    String? detail,
  }) async {
    await prefs.setString(_recordingStatusPrefsKey, status);
    service.invoke('sos_recording_status', {
      'status': status,
      'isActive': isActive,
      'path': path,
      'publicPath': publicPath,
      'detail': detail,
    });
    debugPrint(
      '[SOS Recording] $status'
      '${path == null ? '' : ' - $path'}'
      '${publicPath == null ? '' : ' -> $publicPath'}'
      '${detail == null ? '' : ' - $detail'}',
    );
  }

  Future<void> persistRecordingState({
    required bool active,
    String? sessionId,
    String? path,
    String? fileName,
    String? publicPath,
    int? partNumber,
    int? startedAtMs,
  }) async {
    await prefs.setBool(_recordingActivePrefsKey, active);
    if (sessionId == null) {
      await prefs.remove(_recordingSessionPrefsKey);
    } else {
      await prefs.setString(_recordingSessionPrefsKey, sessionId);
    }
    if (path == null) {
      await prefs.remove(_recordingPathPrefsKey);
    } else {
      await prefs.setString(_recordingPathPrefsKey, path);
    }
    if (fileName == null) {
      await prefs.remove(_recordingFileNamePrefsKey);
    } else {
      await prefs.setString(_recordingFileNamePrefsKey, fileName);
    }
    if (publicPath == null) {
      await prefs.remove(_recordingPublicPathPrefsKey);
    } else {
      await prefs.setString(_recordingPublicPathPrefsKey, publicPath);
    }
    if (partNumber == null) {
      await prefs.remove(_recordingPartPrefsKey);
    } else {
      await prefs.setInt(_recordingPartPrefsKey, partNumber);
    }
    if (startedAtMs == null) {
      await prefs.remove(_recordingStartedAtPrefsKey);
    } else {
      await prefs.setInt(_recordingStartedAtPrefsKey, startedAtMs);
    }
  }

  Future<String> preparePrivateRecordingPath(String fileName) async {
    final baseDir = await getApplicationSupportDirectory();
    final targetDir = Directory(
      '${baseDir.path}${Platform.pathSeparator}sos_recordings',
    );
    if (!targetDir.existsSync()) {
      await targetDir.create(recursive: true);
    }
    return '${targetDir.path}${Platform.pathSeparator}$fileName';
  }

  Future<String?> copyRecordingToDownloads(
    String sourcePath,
    String displayName,
  ) async {
    try {
      final response = await _platformChannel
          .invokeMethod<Map<dynamic, dynamic>>('saveRecordingToDownloads', {
            'sourcePath': sourcePath,
            'displayName': displayName,
          });
      final data = Map<String, dynamic>.from(response ?? const {});
      if (data['success'] == true) {
        return data['publicPath']?.toString();
      }
      debugPrint(
        '[SOS Recording] Failed to copy to Downloads: ${data['errorMessage']}',
      );
    } catch (e) {
      debugPrint('[SOS Recording] Error copying to Downloads: $e');
    }
    return null;
  }

  Future<List<String>> loadBackgroundEmergencyContacts(String uid) async {
    final contacts = <String>[];

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = doc.data();
      if (data != null) {
        for (var index = 1; index <= 4; index++) {
          final value = data['emergencyContact$index']?.toString().trim();
          if (value != null && value.isNotEmpty) {
            contacts.add(value);
          }
        }
      }
    } catch (e) {
      debugPrint(
        '[SOS SMS] Failed to read Firestore contacts in background: $e',
      );
    }

    if (contacts.isEmpty) {
      contacts.addAll(
        (prefs.getStringList('emergency_contacts') ?? const <String>[])
            .map((contact) => contact.trim())
            .where((contact) => contact.isNotEmpty),
      );
    }

    return contacts.toSet().toList();
  }

  Future<String> buildBackgroundSosMessage({
    required String uid,
    required Position position,
  }) async {
    return EmergencyMessageHelper.buildSosMessage(
      uid: uid,
      lat: position.latitude.toStringAsFixed(6),
      lng: position.longitude.toStringAsFixed(6),
      sessionId: uid,
    );
  }

  Future<NativeSmsSendResult> sendBackgroundDirectSms(
    String phoneNumber,
    String message, {
    int? subscriptionId,
  }) async {
    try {
      final response = await _platformChannel
          .invokeMethod<Map<dynamic, dynamic>>('sendDirectSms', {
            'phoneNumber': phoneNumber,
            'message': message,
            'subscriptionId': subscriptionId,
          });
      final data = Map<String, dynamic>.from(response ?? const {});
      return NativeSmsSendResult(
        success: data['success'] == true,
        errorMessage: data['errorMessage']?.toString(),
      );
    } on PlatformException catch (e) {
      return NativeSmsSendResult(
        success: false,
        errorMessage: e.message ?? e.code,
      );
    } catch (e) {
      return NativeSmsSendResult(success: false, errorMessage: e.toString());
    }
  }

  Future<void> dispatchBackgroundEmergencySms({
    required String uid,
    required Position position,
  }) async {
    final contacts = await loadBackgroundEmergencyContacts(uid);
    if (contacts.isEmpty) {
      debugPrint(
        '[SOS SMS] No emergency contacts available for background SOS.',
      );
      return;
    }

    final message = await buildBackgroundSosMessage(
      uid: uid,
      position: position,
    );
    await prefs.setString('sos_msg', message);
    final preferredSubscriptionId = prefs.getInt(
      _preferredSmsSubscriptionPrefsKey,
    );
    final failedNumbers = <String>[];

    for (var index = 0; index < contacts.length; index++) {
      final number = contacts[index];
      var sent = false;

      for (var attempt = 1; attempt <= 2; attempt++) {
        final result = await sendBackgroundDirectSms(
          number,
          message,
          subscriptionId: preferredSubscriptionId,
        );
        if (result.success) {
          sent = true;
          debugPrint('[SOS SMS] Background SMS sent to $number.');
          break;
        }

        debugPrint(
          '[SOS SMS] Background SMS attempt $attempt failed for $number: '
          '${result.errorMessage}',
        );
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }

      if (!sent) {
        failedNumbers.add(number);
      }

      if (index < contacts.length - 1) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }

    if (failedNumbers.isNotEmpty) {
      debugPrint(
        '[SOS SMS] Background SMS failed for '
        '${failedNumbers.length}/${contacts.length} contacts. '
        'Backup share remains available when the app is foregrounded.',
      );
    }
  }

  Future<bool> shouldContinueRecording(String sessionId) async {
    if (!(prefs.getBool(_sosStatePrefsKey) ?? false)) {
      return false;
    }

    try {
      final session = await FirebaseFirestore.instance
          .collection('active_sos')
          .doc(sessionId)
          .get();
      return session.exists && session.data()?['active'] == true;
    } catch (e) {
      debugPrint('[SOS Recording] Failed to verify active SOS session: $e');
      return prefs.getBool(_sosStatePrefsKey) ?? false;
    }
  }

  late Future<void> Function({bool dueToTimeout, bool dueToRecovery})
  stopEmergencyRecording;
  late Future<bool> Function(
    String sessionId, {
    bool resetSequence,
    int? forcedPartNumber,
  })
  startEmergencyRecording;

  stopEmergencyRecording =
      ({bool dueToTimeout = false, bool dueToRecovery = false}) async {
        if (!isRecording) {
          if (dueToRecovery) {
            await persistRecordingState(active: false);
          }
          return;
        }

        recordingTimeoutTimer?.cancel();
        recordingTimeoutTimer = null;

        final sessionId = prefs.getString(_recordingSessionPrefsKey);
        final currentFileName = prefs.getString(_recordingFileNamePrefsKey);
        final currentPart = prefs.getInt(_recordingPartPrefsKey) ?? 1;

        String? privatePath;
        try {
          privatePath = await recorder.stop();
        } catch (e) {
          debugPrint('[SOS Recording] Failed to stop recorder: $e');
        }

        isRecording = false;

        var continuedWithNextSegment = false;
        if (dueToTimeout &&
            sessionId != null &&
            sessionId.isNotEmpty &&
            await shouldContinueRecording(sessionId)) {
          continuedWithNextSegment = await startEmergencyRecording(
            sessionId,
            resetSequence: false,
            forcedPartNumber: currentPart + 1,
          );
        }

        String? publicPath;
        if (privatePath != null &&
            privatePath.isNotEmpty &&
            currentFileName != null &&
            currentFileName.isNotEmpty) {
          publicPath = await copyRecordingToDownloads(
            privatePath,
            currentFileName,
          );
        }

        if (continuedWithNextSegment) {
          if (publicPath != null) {
            await prefs.setString(_recordingPublicPathPrefsKey, publicPath);
          }
          await emitRecordingStatus(
            'Recording segment $currentPart saved. Continuing emergency audio...',
            isActive: true,
            path: prefs.getString(_recordingPathPrefsKey),
            publicPath: publicPath,
            detail: dueToRecovery
                ? 'Recovered from interrupted recording state.'
                : null,
          );
          return;
        }

        await persistRecordingState(
          active: false,
          sessionId: sessionId,
          path: privatePath,
          fileName: currentFileName,
          publicPath: publicPath,
          partNumber: currentPart,
        );

        if (privatePath != null &&
            privatePath.isNotEmpty &&
            File(privatePath).existsSync() &&
            File(privatePath).lengthSync() > 0 &&
            sessionId != null &&
            sessionId.isNotEmpty) {
          final startedMs = prefs.getInt(_recordingStartedAtPrefsKey) ?? DateTime.now().millisecondsSinceEpoch;
          final durationSecs = (DateTime.now().millisecondsSinceEpoch - startedMs) ~/ 1000;
          await HistoryController.instanceOrCreate().updateSosRecordingInfo(
            sosId: sessionId,
            recordingFilePath: privatePath,
            durationSeconds: durationSecs > 0 ? durationSecs : 10,
            uploadStatus: 'local',
          );
        }

        await emitRecordingStatus(
          dueToTimeout
              ? 'Recording stopped after 10 minutes'
              : 'Recording saved',
          isActive: false,
          path: privatePath,
          publicPath: publicPath,
          detail: dueToRecovery
              ? 'Recovered from interrupted recording state.'
              : null,
        );
        await updateServiceNotification(
          title: 'VIGIL Active',
          content: idleMonitoringContent(),
        );
      };

  startEmergencyRecording =
      (
        String sessionId, {
        bool resetSequence = false,
        int? forcedPartNumber,
      }) async {
        if (isRecording) {
          return true;
        }

        if (isListening) {
          try {
            await speechToText.stop();
            isListening = false;
            debugPrint('[SOS Recording] Released speechToText microphone lock.');
          } catch (e) {
            debugPrint('[SOS Recording] Error stopping speechToText: $e');
          }
        }

        if (!await recorder.hasPermission()) {
          await emitRecordingStatus(
            'Recording unavailable',
            isActive: false,
            detail: 'Microphone permission not granted.',
          );
          return false;
        }

        final partNumber =
            forcedPartNumber ??
            (resetSequence
                ? 1
                : (prefs.getInt(_recordingPartPrefsKey) ?? 0) + 1);
        final fileName = buildSosRecordingFileName(
          sessionId,
          partNumber,
          DateTime.now(),
        );
        final path = await preparePrivateRecordingPath(fileName);
        final startedAtMs = DateTime.now().millisecondsSinceEpoch;

        try {
          await recorder.start(
            const RecordConfig(
              encoder: AudioEncoder.aacLc,
              bitRate: 128000,
              sampleRate: 44100,
            ),
            path: path,
          );
          isRecording = true;
          await persistRecordingState(
            active: true,
            sessionId: sessionId,
            path: path,
            fileName: fileName,
            partNumber: partNumber,
            startedAtMs: startedAtMs,
          );
          await emitRecordingStatus(
            'Recording emergency audio... segment $partNumber',
            isActive: true,
            path: path,
          );
          await updateServiceNotification(
            title: 'SOS audio recording active',
            content:
                'VIGIL is recording emergency audio in the background.',
          );
          recordingTimeoutTimer?.cancel();
          recordingTimeoutTimer = Timer(
            _recordingMaxDuration,
            () => stopEmergencyRecording(dueToTimeout: true),
          );
          return true;
        } catch (e) {
          await emitRecordingStatus(
            'Recording unavailable',
            isActive: false,
            detail: e.toString(),
          );
          debugPrint('[SOS Recording] Failed to start recorder: $e');
          return false;
        }
      };

  late Future<void> Function() startVoiceScan;

  Future<void> triggerVoiceSosCountdown(String recognizedWords) async {
    final now = DateTime.now();
    if (isCountdownActive) {
      return;
    }
    if (lastVoiceTriggerAt != null &&
        now.difference(lastVoiceTriggerAt!).inMilliseconds <
            _voiceSosCooldownMs) {
      return;
    }

    lastVoiceTriggerAt = now;
    isCountdownActive = true;
    isListening = false;
    currentVoiceState = 'TRIGGERING_SOS';

    // Release microphone lock cleanly before initiating emergency sequence / audio recorder
    try {
      await speechToText.stop();
      await speechToText.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } catch (e) {
      debugPrint('[Voice SOS] Error releasing mic lock: $e');
    }

    final hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator == true) {
      Vibration.vibrate(pattern: [500, 200, 500, 200, 500]);
    }

    final executeAt = DateTime.now()
        .add(const Duration(seconds: _voiceCountdownSeconds))
        .millisecondsSinceEpoch;
    await prefs.setInt('sos_execute_at', executeAt);
    await prefs.setBool('is_sos_pending', true);
    await prefs.setString(_sosPendingOwnerPrefsKey, 'background');

    service.invoke('sos_triggered', {'executeAt': executeAt});
    await emitVoiceStatus(
      'Voice SOS keyword detected',
      isActive: true,
      detail: recognizedWords,
    );

    try {
      final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
      const initializationSettingsAndroid = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      const initializationSettings = InitializationSettings(
        android: initializationSettingsAndroid,
      );
      await flutterLocalNotificationsPlugin.initialize(
        settings: initializationSettings,
      );

      await flutterLocalNotificationsPlugin.show(
        id: 778,
        title: 'Voice SOS detected',
        body: 'VIGIL will trigger SOS in $_voiceCountdownSeconds seconds.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'sos_wake_channel_v1',
            'SOS Critical Wake Lock',
            icon: '@mipmap/ic_launcher',
            channelDescription: 'Voice SOS wake',
            importance: Importance.max,
            priority: Priority.max,
            fullScreenIntent: true,
            visibility: NotificationVisibility.public,
            ongoing: true,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Voice SOS] Notification error: $e');
    }

    try {
      await launchUrl(
        Uri.parse('saferoute://sos'),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint("Deep link bypass failed: $e");
    }

    Timer(const Duration(seconds: _voiceCountdownSeconds), () async {
      isCountdownActive = false;
      await prefs.reload();
      final isPending = prefs.getBool('is_sos_pending') ?? false;
      final pendingOwner = prefs.getString(_sosPendingOwnerPrefsKey);

      if (isPending) {
        final backgroundResult = await _executeBackgroundSOS();
        if (backgroundResult != null) {
          await dispatchBackgroundEmergencySms(
            uid: backgroundResult.uid,
            position: backgroundResult.position,
          );
          await startEmergencyRecording(
            backgroundResult.uid,
            resetSequence: true,
          );
        }
        await prefs.setBool('is_sos_pending', false);
        await prefs.remove(_sosPendingOwnerPrefsKey);
      }

      if (prefs.getBool(_voiceSosEnabledPrefsKey) ?? false) {
        unawaited(startVoiceScan());
      }
    });
  }

  Future<void> restartVoiceListenSession() async {
    if (isCountdownActive || !(prefs.getBool(_voiceSosEnabledPrefsKey) ?? false)) {
      return;
    }
    if (speechToText.isListening) {
      return;
    }

    try {
      isListening = true;
      currentVoiceState = 'LISTENING';
      await emitVoiceStatus('Listening for voice SOS...', isActive: true);

      await speechToText.listen(
        onResult: (result) async {
          final spokenWords = result.recognizedWords.trim();
          if (spokenWords.isEmpty) return;

          lastVoiceTranscript = spokenWords;
          debugPrint('[Voice SOS] Dictation: "$spokenWords" (final: ${result.finalResult})');

          if (isCountdownActive) return;

          if (matchesEmergencyVoicePhrase(spokenWords)) {
            currentVoiceState = 'KEYWORD_DETECTED';
            try {
              await speechToText.stop();
            } catch (_) {}
            await triggerVoiceSosCountdown(spokenWords);
          } else {
            currentVoiceState = 'RECOGNIZING';
          }
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
          autoPunctuation: false,
          enableHapticFeedback: false,
        ),
      );
    } catch (e) {
      isListening = false;
      currentVoiceState = 'ERROR';
      lastVoiceError = e.toString();
      debugPrint('[Voice SOS] Error in restartVoiceListenSession: $e');
    }
  }

  startVoiceScan = () async {
    if (!(prefs.getBool(_voiceSosEnabledPrefsKey) ?? false)) {
      currentVoiceState = 'DISABLED';
      await emitVoiceStatus('Voice SOS disabled', isActive: false);
      return;
    }

    if (isCountdownActive || speechToText.isListening) {
      return;
    }

    try {
      final micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        final requested = await Permission.microphone.request();
        if (!requested.isGranted) {
          currentVoiceState = 'UNAVAILABLE';
          await emitVoiceStatus(
            'Voice SOS unavailable',
            isActive: false,
            detail: 'Microphone permission not granted.',
          );
          return;
        }
      }

      // Single-instance initialization to avoid ERROR_RECOGNIZER_BUSY
      if (!isSpeechToTextInitialized) {
        currentVoiceState = 'INITIALIZING';
        final available = await speechToText.initialize(
          onStatus: (status) async {
            debugPrint('[Voice SOS] Listener status: $status');
            if (status == 'listening') {
              isListening = true;
              currentVoiceState = 'LISTENING';
              await emitVoiceStatus('Listening for voice SOS...', isActive: true);
            } else if (status == 'done' || status == 'notListening') {
              isListening = false;
              if (currentVoiceState != 'TRIGGERING_SOS' && currentVoiceState != 'KEYWORD_DETECTED') {
                currentVoiceState = 'RESTARTING';
              }
              await Future<void>.delayed(const Duration(milliseconds: 100));
              if (!isCountdownActive && (prefs.getBool(_voiceSosEnabledPrefsKey) ?? false)) {
                unawaited(restartVoiceListenSession());
              }
            }
          },
          onError: (errorNotification) async {
            debugPrint('[Voice SOS] Listener error: ${errorNotification.errorMsg}');
            isListening = false;
            lastVoiceError = errorNotification.errorMsg;

            final errorStr = errorNotification.errorMsg.toLowerCase();
            final isBenignSilenceTimeout = errorStr.contains('no_match') ||
                errorStr.contains('speech_timeout') ||
                errorStr.contains('timeout') ||
                errorStr.contains('network_timeout') ||
                errorStr.contains('client');

            if (isBenignSilenceTimeout) {
              // Normal silence cycle, seamlessly restart without spamming UI or long exponential backoff
              if (currentVoiceState != 'TRIGGERING_SOS' && currentVoiceState != 'KEYWORD_DETECTED') {
                currentVoiceState = 'RESTARTING';
              }
              await Future<void>.delayed(const Duration(milliseconds: 100));
              if (!isCountdownActive && (prefs.getBool(_voiceSosEnabledPrefsKey) ?? false)) {
                unawaited(restartVoiceListenSession());
              }
              return;
            }

            voiceRestartCount++;
            if (currentVoiceState != 'TRIGGERING_SOS') {
              currentVoiceState = 'ERROR';
            }

            await emitVoiceStatus(
              'Voice SOS issue: ${errorNotification.errorMsg}',
              isActive: false,
              detail: errorNotification.errorMsg,
            );

            // Controlled cooldown for genuine errors
            final backoffMs = (400 + (voiceRestartCount % 3) * 300);
            await Future<void>.delayed(Duration(milliseconds: backoffMs));

            if (!isCountdownActive && (prefs.getBool(_voiceSosEnabledPrefsKey) ?? false)) {
              unawaited(restartVoiceListenSession());
            }
          },
        );

        if (!available) {
          currentVoiceState = 'UNAVAILABLE';
          await emitVoiceStatus(
            'Voice SOS unavailable',
            isActive: false,
            detail: 'Speech recognition service not available.',
          );
          return;
        }

        isSpeechToTextInitialized = true;
      }

      await updateServiceNotification(
        title: 'VIGIL Active',
        content: idleMonitoringContent(),
      );

      await restartVoiceListenSession();
    } catch (e) {
      isListening = false;
      currentVoiceState = 'ERROR';
      lastVoiceError = e.toString();
      await emitVoiceStatus(
        'Voice SOS unavailable',
        isActive: false,
        detail: e.toString(),
      );
      debugPrint('[Voice SOS] Exception in startVoiceScan: $e');
    }
  };

  Future<void> stopVoiceScan() async {
    if (isListening) {
      try {
        await speechToText.stop();
      } catch (_) {}
    }
    isListening = false;
    currentVoiceState = 'DISABLED';
    await emitVoiceStatus('Voice SOS disabled', isActive: false);
    await emitVoiceStatus('Voice SOS disabled', isActive: false);
    await updateServiceNotification(
      title: 'VIGIL Active',
      content: idleMonitoringContent(),
    );
  }

  FirebaseFirestore.instance
      .collection('active_sos')
      .where('active', isEqualTo: true)
      .snapshots()
      .listen((snapshot) async {
        for (var change in snapshot.docChanges) {
          if (change.type != DocumentChangeType.added) {
            continue;
          }

          final data = change.doc.data();
          if (data == null) {
            continue;
          }

          final uid = data['uid'] as String?;
          final lat = data['latitude'] as double?;
          final lng = data['longitude'] as double?;

          if (uid == null || lat == null || lng == null) {
            continue;
          }

          final prefs = await SharedPreferences.getInstance();
          final currentUserId = prefs.getString('user_uid');
          if (currentUserId != null && uid == currentUserId) {
            continue;
          }

          if (notifiedSosList.contains(uid)) {
            continue;
          }

          try {
            final position = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.medium,
              ),
            );

            final distanceInMeters = Geolocator.distanceBetween(
              position.latitude,
              position.longitude,
              lat,
              lng,
            );

            if (distanceInMeters <= 5000) {
              notifiedSosList.add(uid);

              final plugin = FlutterLocalNotificationsPlugin();
              await plugin.show(
                id: uid.hashCode,
                title: 'ðŸš¨ NEARBY DANGER ALERT',
                body:
                    'Someone needs help ${(distanceInMeters / 1000).toStringAsFixed(1)}km away! Tap to navigate.',
                notificationDetails: const NotificationDetails(
                  android: AndroidNotificationDetails(
                    'sos_nearby_channel_v1',
                    'Nearby SOS Alerts',
                    icon: '@mipmap/ic_launcher',
                    channelDescription:
                        'Alerts you instantly when a user triggers an emergency nearby.',
                    importance: Importance.max,
                    priority: Priority.max,
                  ),
                ),
              );
            }
          } catch (e) {
            debugPrint("Background SOS Listener Error: $e");
          }
        }
      });

  service.on('stopService').listen((event) async {
    accelerometerSubscription?.cancel();
    detector.reset();
    await stopVoiceScan();
    await stopEmergencyRecording(dueToRecovery: true);
    service.stopSelf();
  });

  service.on('setShakeSosEnabled').listen((event) async {
    isShakeEnabled = event?['enabled'] == true;
    await prefs.setBool(_shakeSosEnabledPrefsKey, isShakeEnabled);
    if (!isShakeEnabled) {
      detector.reset();
    }
    await updateServiceNotification(
      title: 'VIGIL Active',
      content: idleMonitoringContent(),
    );
  });

  service.on('setVoiceSosEnabled').listen((event) async {
    final enabled = event?['enabled'] == true;
    await prefs.setBool(_voiceSosEnabledPrefsKey, enabled);
    if (enabled) {
      await emitVoiceStatus('Listening for voice SOS...', isActive: true);
      unawaited(startVoiceScan());
    } else {
      await stopVoiceScan();
    }
    await updateServiceNotification(
      title: 'VIGIL Active',
      content: idleMonitoringContent(),
    );
  });

  service.on('startSosRecording').listen((event) async {
    final sessionId = event?['sessionId']?.toString().trim();
    if (sessionId == null || sessionId.isEmpty) {
      await emitRecordingStatus(
        'Recording unavailable',
        isActive: false,
        detail: 'Missing SOS session ID.',
      );
      return;
    }
    await startEmergencyRecording(sessionId, resetSequence: true);
  });

  service.on('stopSosRecording').listen((event) async {
    await stopEmergencyRecording();
  });

  accelerometerSubscription = userAccelerometerEventStream().listen((
    UserAccelerometerEvent event,
  ) async {
    if (!isShakeEnabled || isCountdownActive) {
      return;
    }

    final detected = detector.register(event, DateTime.now());
    if (!detected) {
      return;
    }

    isCountdownActive = true;

    final hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator == true) {
      Vibration.vibrate(pattern: [300, 180, 300]);
    }

    final prefs = await SharedPreferences.getInstance();
    final executeAt = DateTime.now()
        .add(const Duration(seconds: _cancelCountdownSeconds))
        .millisecondsSinceEpoch;
    await prefs.setInt('sos_execute_at', executeAt);
    await prefs.setBool('is_sos_pending', true);
    await prefs.setString(_sosPendingOwnerPrefsKey, 'background');

    service.invoke('sos_triggered', {'executeAt': executeAt});

    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const initializationSettingsAndroid = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
    await flutterLocalNotificationsPlugin.initialize(
      settings: initializationSettings,
    );

    await flutterLocalNotificationsPlugin.show(
      id: 777,
      title: 'ðŸš¨ URGENT: SOS COUNTDOWN STARTED',
      body: 'Tap to open and cancel if this was a mistake.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'sos_wake_channel_v1',
          'SOS Critical Wake Lock',
          channelDescription:
              'Wakes the screen when shaking is detected natively',
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: true,
          visibility: NotificationVisibility.public,
          ongoing: true,
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );

    try {
      await launchUrl(
        Uri.parse('saferoute://sos'),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint("Deep link bypass failed: $e");
    }

    Timer(const Duration(seconds: _cancelCountdownSeconds), () async {
      isCountdownActive = false;
      detector.markTriggerHandled(DateTime.now());

      await prefs.reload();
      final isPending = prefs.getBool('is_sos_pending') ?? false;
      final pendingOwner = prefs.getString(_sosPendingOwnerPrefsKey);

      if (isPending && pendingOwner != 'ui') {
        final backgroundResult = await _executeBackgroundSOS();
        if (backgroundResult != null) {
          await dispatchBackgroundEmergencySms(
            uid: backgroundResult.uid,
            position: backgroundResult.position,
          );
          await startEmergencyRecording(
            backgroundResult.uid,
            resetSequence: true,
          );
        }
        await prefs.setBool('is_sos_pending', false);
        await prefs.remove(_sosPendingOwnerPrefsKey);
      }
    });
  });

  final persistedSessionId = prefs.getString(_recordingSessionPrefsKey);
  final shouldRecoverRecording =
      prefs.getBool(_recordingActivePrefsKey) ?? false;
  if (shouldRecoverRecording &&
      persistedSessionId != null &&
      persistedSessionId.isNotEmpty) {
    try {
      final persistedPath = prefs.getString(_recordingPathPrefsKey);
      final persistedFileName = prefs.getString(_recordingFileNamePrefsKey);
      final persistedPart = prefs.getInt(_recordingPartPrefsKey) ?? 0;
      final activeSession = await FirebaseFirestore.instance
          .collection('active_sos')
          .doc(persistedSessionId)
          .get();
      if (activeSession.exists && activeSession.data()?['active'] == true) {
        if (persistedPath != null &&
            persistedFileName != null &&
            File(persistedPath).existsSync()) {
          final recoveredPublicPath = await copyRecordingToDownloads(
            persistedPath,
            persistedFileName,
          );
          if (recoveredPublicPath != null) {
            await prefs.setString(
              _recordingPublicPathPrefsKey,
              recoveredPublicPath,
            );
          }
        }
        await startEmergencyRecording(
          persistedSessionId,
          resetSequence: false,
          forcedPartNumber: persistedPart <= 0 ? 1 : persistedPart + 1,
        );
      } else {
        await persistRecordingState(active: false);
      }
    } catch (e) {
      debugPrint('[SOS Recording] Recovery check failed: $e');
      await persistRecordingState(active: false);
    }
  }

  if (prefs.getBool(_voiceSosEnabledPrefsKey) ?? false) {
    unawaited(startVoiceScan());
  } else {
    await emitVoiceStatus('Voice SOS disabled', isActive: false);
  }
  await updateServiceNotification(
    title: 'VIGIL Active',
    content: idleMonitoringContent(),
  );

  /*
  // --- Voice SOS Engine (legacy block removed) ---
  final SpeechToText speechToText = SpeechToText();
  bool isListening = false;

  Future<void> startVoiceScan() async {
    if (isCountdownActive) return; // Prevent double trigger

    try {
      bool available = await speechToText.initialize(
        onStatus: (status) async {
          if (status == 'done' || status == 'notListening') {
            isListening = false;
            // Brief pause before auto-restart to prevent resource locking
            await Future.delayed(const Duration(seconds: 2));
            if (!isCountdownActive) {
              startVoiceScan();
            }
          }
        },
        onError: (errorNotification) async {
          isListening = false;
          // Longer pause on actual errors (e.g., no microhone access initially)
          await Future.delayed(const Duration(seconds: 4));
          if (!isCountdownActive) {
            startVoiceScan();
          }
        },
      );

      if (available && !isListening && !isCountdownActive) {
        isListening = true;
        await speechToText.listen(
          onResult: (result) async {
            if (isCountdownActive) return;

            if (result.confidence > 0.0 && result.confidence < 0.6) {
              return; // Ignore low confidence parses to avoid false triggers
            }

            final spokenWords = result.recognizedWords.toLowerCase();
            if (spokenWords.contains('help me') ||
                spokenWords.contains('save me') ||
                spokenWords.contains('sos')) {
              isCountdownActive = true;
              speechToText.stop();

              final hasVibrator = await Vibration.hasVibrator();
              if (hasVibrator == true) {
                Vibration.vibrate(pattern: [500, 200, 500, 200, 500]);
              }

              final prefs = await SharedPreferences.getInstance();
              final executeAt = DateTime.now()
                  .add(const Duration(seconds: 5)) // Custom 5 sec warning
                  .millisecondsSinceEpoch;
              await prefs.setInt('sos_execute_at', executeAt);
              await prefs.setBool('is_sos_pending', true);

              service.invoke('sos_triggered', {'executeAt': executeAt});

              final flutterLocalNotificationsPlugin =
                  FlutterLocalNotificationsPlugin();
              const initializationSettingsAndroid =
                  AndroidInitializationSettings('@mipmap/ic_launcher');
              const initializationSettings = InitializationSettings(
                android: initializationSettingsAndroid,
              );
              await flutterLocalNotificationsPlugin.initialize(
                settings: initializationSettings,
              );

              await flutterLocalNotificationsPlugin.show(
                id: 778, // Separate unique ID from shake
                title: '🚨 Voice SOS Detected',
                body: 'Sending alert in 5 seconds. Tap to cancel.',
                notificationDetails: const NotificationDetails(
                  android: AndroidNotificationDetails(
                    'sos_wake_channel_v1',
                    'SOS Critical Wake Lock',
                    channelDescription: 'Voice SOS wake',
                    importance: Importance.max,
                    priority: Priority.max,
                    fullScreenIntent: true,
                    visibility: NotificationVisibility.public,
                    ongoing: true,
                  ),
                ),
              );

              try {
                await launchUrl(
                  Uri.parse('saferoute://sos'),
                  mode: LaunchMode.externalApplication,
                );
              } catch (e) {
                debugPrint("Deep link bypass failed: $e");
              }

              Timer(const Duration(seconds: 5), () async {
                isCountdownActive = false;

                await prefs.reload();
                final isPending = prefs.getBool('is_sos_pending') ?? false;

                if (isPending) {
                  await _executeBackgroundSOS();
                  await prefs.setBool('is_sos_pending', false);
                }

                // Safely resume endless voice scanning
                startVoiceScan();
              });
            }
          },
          listenMode: ListenMode.dictation,
          partialResults: false,
        );
      }
    } catch (e) {
      debugPrint("Speech recognizer exception: $e");
      isListening = false;
    }
  }

  // Kickstart voice tracking loop
  startVoiceScan();
  */
}

Future<_BackgroundSosExecutionResult?> _executeBackgroundSOS() async {
  try {
    final hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator == true) {
      Vibration.vibrate(pattern: [1000, 1000, 1000, 1000]);
    }

    final prefs = await SharedPreferences.getInstance();
    final uid = prefs.getString('user_uid');
    if (uid == null || uid.isEmpty) {
      return null;
    }

    final existingSession = await FirebaseFirestore.instance
        .collection('active_sos')
        .doc(uid)
        .get();
    if (existingSession.exists && existingSession.data()?['active'] == true) {
      await prefs.setBool(_sosStatePrefsKey, true);
      return null;
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
    );
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    await FirebaseFirestore.instance.collection('active_sos').doc(uid).set({
      'sessionId': uid,
      'uid': uid,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'victim': {
        'lat': position.latitude,
        'lng': position.longitude,
        'lastUpdated': FieldValue.serverTimestamp(),
        'lastUpdatedMs': nowMs,
      },
      'timestamp': FieldValue.serverTimestamp(),
      'startedAtMs': nowMs,
      'updatedAtMs': nowMs,
      'active': true,
      'status': 'active',
      'responders': [],
      'respondersMeta': {},
      'inviteTokens': {},
      'invitedHelpers': {},
      'responderCount': 0,
      'rescueState': 'waiting_for_responder',
    });
    await prefs.setBool(_sosStatePrefsKey, true);
    return _BackgroundSosExecutionResult(uid: uid, position: position);
  } catch (e) {
    debugPrint("Background SOS Execution Error: $e");
    return null;
  }
}

class _BackgroundSosExecutionResult {
  const _BackgroundSosExecutionResult({
    required this.uid,
    required this.position,
  });

  final String uid;
  final Position position;
}

class NativeSmsSendResult {
  const NativeSmsSendResult({required this.success, this.errorMessage});

  final bool success;
  final String? errorMessage;
}

class EmergencyShakeDetector {
  final List<DateTime> _shakeMoments = [];
  final List<DateTime> _violentSnatchMoments = [];
  int _lastAxisDirection = 0;
  DateTime? _lastShakeAt;
  DateTime? _cooldownUntil;

  bool register(UserAccelerometerEvent event, DateTime now) {
    if (_cooldownUntil != null && now.isBefore(_cooldownUntil!)) {
      return false;
    }

    final magnitude = sqrt(pow(event.x, 2) + pow(event.y, 2) + pow(event.z, 2));
    if (magnitude < _strongShakeMagnitudeThreshold) {
      _prune(now);
      return false;
    }

    final dominantAxisValue = _dominantAxisValue(event);
    if (dominantAxisValue.abs() < _axisDirectionThreshold) {
      return false;
    }

    final direction = dominantAxisValue.isNegative ? -1 : 1;
    if (_lastAxisDirection != 0 && direction == _lastAxisDirection) {
      return false;
    }

    if (_lastShakeAt != null) {
      final gapMs = now.difference(_lastShakeAt!).inMilliseconds;
      if (gapMs < _minShakeGapMs) {
        return false;
      }
      if (gapMs > _maxShakeGapMs) {
        reset();
      }
    }

    _lastAxisDirection = direction;
    _lastShakeAt = now;
    _shakeMoments.add(now);

    // Track sudden violent snatch shocks (e.g. violent physical tug / snatch)
    if (magnitude >= _violentSnatchMagnitudeThreshold) {
      _violentSnatchMoments.add(now);
    }

    _prune(now);

    // 1. Violent Snatch & Physical Struggle Condition: >= 2 extreme violent shocks within 700ms
    if (_violentSnatchMoments.length >= 2) {
      final snatchDuration = _violentSnatchMoments.last
          .difference(_violentSnatchMoments.first)
          .inMilliseconds;
      if (snatchDuration <= 700) {
        return true;
      }
      _violentSnatchMoments.removeAt(0);
    }

    // 2. High-Force Intentional Emergency Shake / Struggle: >= 4 strong alternating oscillations within 1700ms
    if (_shakeMoments.length >= _requiredStrongOscillations) {
      final sequenceDuration = _shakeMoments.last
          .difference(_shakeMoments.first)
          .inMilliseconds;
      if (sequenceDuration <= _shakeSequenceWindowMs) {
        return true;
      }
      _shakeMoments.removeAt(0);
    }

    return false;
  }

  void markTriggerHandled(DateTime now) {
    _cooldownUntil = now.add(const Duration(milliseconds: _sosCooldownMs));
    reset(keepCooldown: true);
  }

  void reset({bool keepCooldown = false}) {
    _shakeMoments.clear();
    _violentSnatchMoments.clear();
    _lastAxisDirection = 0;
    _lastShakeAt = null;
    if (!keepCooldown) {
      _cooldownUntil = null;
    }
  }

  void _prune(DateTime now) {
    _shakeMoments.removeWhere(
      (timestamp) =>
          now.difference(timestamp).inMilliseconds > _shakeSequenceWindowMs,
    );
    _violentSnatchMoments.removeWhere(
      (timestamp) => now.difference(timestamp).inMilliseconds > 800,
    );
  }

  double _dominantAxisValue(UserAccelerometerEvent event) {
    final values = [event.x, event.y, event.z];
    values.sort((a, b) => b.abs().compareTo(a.abs()));
    return values.first;
  }
}
