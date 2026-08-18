import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vibration/vibration.dart';
import '../services/location_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import '../screens/emergency_sos_screen.dart';
import '../services/emergency_dispatch_engine.dart';
import '../services/emergency_message_helper.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/background_shake_service.dart';
import 'contact_controller.dart';
import 'history_controller.dart';
import 'journey_guard_controller.dart';
import 'sos_listener_controller.dart';
import 'sos_settings_controller.dart';

class SosController extends GetxController with WidgetsBindingObserver {
  static SosController instanceOrCreate() {
    if (Get.isRegistered<SosController>()) {
      return Get.find<SosController>();
    }
    return Get.put(SosController(), permanent: true);
  }

  static const int _sosFreshnessWindowMs = 15 * 60 * 1000;
  static const String _globalStatsDocPath = 'stats/global';
  static const Duration _smsSendGap = Duration(seconds: 3);
  static const Duration _smsRetryGap = Duration(seconds: 3);
  static const int _smsMaxAttemptsPerContact = 2;
  static const int _smsMaxSimSwitchesPerAttempt = 2;
  static const MethodChannel _smsChannel = MethodChannel('safe_route/sms');
  static const String _preferredSmsSubscriptionPrefsKey =
      'preferred_sms_subscription_id';
  static const String _voiceSosPrefsKey = 'is_voice_sos_active';
  static const String _voiceStatusPrefsKey = 'voice_sos_status';
  static const String _recordingStatusPrefsKey = 'sos_recording_status';
  static const String _recordingPathPrefsKey = 'sos_recording_path';
  static const String _recordingPublicPathPrefsKey =
      'sos_recording_public_path';
  static const String _recordingActivePrefsKey = 'sos_recording_active';
  static const String _sosPendingPrefsKey = 'is_sos_pending';
  static const String _sosExecuteAtPrefsKey = 'sos_execute_at';
  static const String _sosPendingOwnerPrefsKey = 'sos_pending_owner';
  static const String _sosActivePrefsKey = 'is_sos_active';

  var isLoading = false.obs;
  var isCountdown = false.obs;
  var countdownSeconds = 10.obs; // INCREASED TO 10 SECONDS
  var isSent = false.obs;
  var isSosModalVisible = false.obs;
  var isActiveBroadcast = false.obs;
  var isCompletingRescue = false.obs;
  var isSendingEmergencyAlerts = false.obs;

  var isShakeSOSActive = false.obs;
  var isVoiceSOSActive = false.obs;
  var isVoiceListening = false.obs;
  var voiceStatusMessage = 'Voice SOS disabled'.obs;
  var voiceState = 'IDLE'.obs;
  var voiceLastTranscript = ''.obs;
  var voiceRestartCount = 0.obs;
  var voiceLastError = 'NONE'.obs;
  var isEmergencyRecording = false.obs;
  var recordingStatusMessage = ''.obs;
  var lastRecordingPrivatePath = ''.obs;
  var lastRecordingPublicPath = ''.obs;
  var smsStatusMessage = 'SOS idle'.obs;
  var smsRetryStatus = ''.obs;
  var smsSentCount = 0.obs;
  var smsFailedCount = 0.obs;
  var smsTotalCount = 0.obs;
  final RxnInt selectedSmsSubscriptionId = RxnInt();
  final availableSmsSubscriptions = <SmsSubscriptionInfo>[].obs;

  String generatedMessage = '';
  Timer? _timer;
  StreamSubscription<Map<String, dynamic>?>? _voiceStatusSubscription;
  StreamSubscription<Map<String, dynamic>?>? _recordingStatusSubscription;

  final SpeechToText _foregroundSpeech = SpeechToText();
  bool _isForegroundSpeechInitialized = false;
  bool _isForegroundListening = false;
  bool _isVoiceProcessing = false;

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    _loadPrefs();
    _voiceStatusSubscription = FlutterBackgroundService()
        .on('voice_sos_status')
        .listen((event) {
          final data = Map<String, dynamic>.from(event ?? const {});
          if (!_isForegroundListening) {
            voiceStatusMessage.value =
                data['status']?.toString() ?? 'Voice SOS disabled';
            isVoiceListening.value = data['isActive'] == true;
          }
          if (data.containsKey('state') && !_isForegroundListening) {
            voiceState.value = data['state']?.toString() ?? 'IDLE';
          }
          if (data.containsKey('lastTranscript')) {
            voiceLastTranscript.value = data['lastTranscript']?.toString() ?? '';
          }
          if (data.containsKey('restartCount')) {
            voiceRestartCount.value = (data['restartCount'] as num?)?.toInt() ?? 0;
          }
          if (data.containsKey('lastError')) {
            voiceLastError.value = data['lastError']?.toString() ?? 'NONE';
          }
        });
    _recordingStatusSubscription = FlutterBackgroundService()
        .on('sos_recording_status')
        .listen((event) {
          final data = Map<String, dynamic>.from(event ?? const {});
          recordingStatusMessage.value = data['status']?.toString() ?? '';
          isEmergencyRecording.value = data['isActive'] == true;
          if (data.containsKey('path')) {
            lastRecordingPrivatePath.value = data['path']?.toString() ?? '';
          }
          if (data.containsKey('publicPath')) {
            lastRecordingPublicPath.value =
                data['publicPath']?.toString() ?? '';
          }
        });
    FlutterBackgroundService().on('sos_triggered').listen((event) async {
      if (!isCountdown.value && !isSent.value) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_sosPendingOwnerPrefsKey, 'ui');
        final executeAt = event?['executeAt'];
        final remainder = (executeAt is int)
            ? ((executeAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil()
            : 3;
        initiateSOSWorkflow(initialCountdown: remainder > 0 ? remainder : 3);

        // Open the exact same Emergency SOS Screen that opens on manual SOS button tap
        Get.to(() => const EmergencySosScreen());
      }
    });
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopForegroundVoiceListening();
    _voiceStatusSubscription?.cancel();
    _recordingStatusSubscription?.cancel();
    _timer?.cancel();
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (isVoiceSOSActive.value && !isCountdown.value && !isSent.value && !isLoading.value && !isActiveBroadcast.value) {
        _startForegroundVoiceListening();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _stopForegroundVoiceListening();
    }
  }

  Future<void> _startForegroundVoiceListening() async {
    if (!isVoiceSOSActive.value || isCountdown.value || isSent.value || isLoading.value || isActiveBroadcast.value) {
      return;
    }
    if (_isForegroundListening || _foregroundSpeech.isListening) {
      return;
    }

    try {
      final micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        return;
      }

      if (!_isForegroundSpeechInitialized) {
        final available = await _foregroundSpeech.initialize(
          onStatus: (status) async {
            debugPrint('[Foreground Voice SOS] Status: $status');
            if (status == 'listening') {
              _isForegroundListening = true;
              voiceStatusMessage.value = 'Listening for voice SOS...';
              isVoiceListening.value = true;
              voiceState.value = 'LISTENING';
            } else if (status == 'done' || status == 'notListening') {
              _isForegroundListening = false;
              if (voiceState.value != 'KEYWORD_DETECTED') {
                voiceState.value = 'RESTARTING';
              }
              await Future.delayed(const Duration(milliseconds: 150));
              if (isVoiceSOSActive.value && !isCountdown.value && !isSent.value && !isLoading.value && !isActiveBroadcast.value) {
                _restartForegroundVoiceListening();
              }
            }
          },
          onError: (errorNotification) async {
            debugPrint('[Foreground Voice SOS] Error: ${errorNotification.errorMsg}');
            _isForegroundListening = false;
            final errorStr = errorNotification.errorMsg.toLowerCase();
            final isBenign = errorStr.contains('no_match') ||
                errorStr.contains('speech_timeout') ||
                errorStr.contains('timeout') ||
                errorStr.contains('network_timeout') ||
                errorStr.contains('client') ||
                errorStr.contains('busy');

            if (isBenign) {
              await Future.delayed(const Duration(milliseconds: 150));
              if (isVoiceSOSActive.value && !isCountdown.value && !isSent.value && !isLoading.value && !isActiveBroadcast.value) {
                _restartForegroundVoiceListening();
              }
            }
          },
        );

        if (!available) {
          debugPrint('[Foreground Voice SOS] Speech recognition not available on this device.');
          return;
        }
        _isForegroundSpeechInitialized = true;
      }

      await _restartForegroundVoiceListening();
    } catch (e) {
      debugPrint('[Foreground Voice SOS] Setup error: $e');
    }
  }

  Future<void> _restartForegroundVoiceListening() async {
    if (!isVoiceSOSActive.value || isCountdown.value || isSent.value || isLoading.value) {
      return;
    }
    if (_foregroundSpeech.isListening) {
      return;
    }

    try {
      _isForegroundListening = true;
      voiceStatusMessage.value = 'Listening for voice SOS...';
      isVoiceListening.value = true;
      voiceState.value = 'LISTENING';

      await _foregroundSpeech.listen(
        onResult: (result) async {
          final spokenWords = result.recognizedWords.trim();
          if (spokenWords.isEmpty) return;

          voiceLastTranscript.value = spokenWords;
          debugPrint('[Foreground Voice SOS] Heard: "$spokenWords" (final: ${result.finalResult})');

          if (isCountdown.value || isSent.value || _isVoiceProcessing) return;

          if (matchesEmergencyVoicePhrase(spokenWords)) {
            _isVoiceProcessing = true;
            voiceState.value = 'KEYWORD_DETECTED';
            voiceStatusMessage.value = 'Voice SOS keyword detected: "$spokenWords"';
            try {
              await _foregroundSpeech.stop();
            } catch (_) {}

            final hasVibrator = await Vibration.hasVibrator();
            if (hasVibrator == true) {
              Vibration.vibrate(pattern: [500, 200, 500, 200, 500]);
            }

            Get.snackbar(
              "🚨 Voice SOS Keyword Detected!",
              'Keyword: "$spokenWords". Triggering Emergency SOS...',
              snackPosition: SnackPosition.TOP,
              backgroundColor: Colors.redAccent,
              colorText: Colors.white,
              duration: const Duration(seconds: 4),
            );

            await initiateSOSWorkflow(initialCountdown: 5);

            Future.delayed(const Duration(seconds: 8), () {
              _isVoiceProcessing = false;
            });
          }
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.deviceDefault,
          partialResults: true,
          cancelOnError: false,
          autoPunctuation: false,
          enableHapticFeedback: false,
        ),
      );
    } catch (e) {
      debugPrint('[Foreground Voice SOS] listen error: $e');
    }
  }

  Future<void> _stopForegroundVoiceListening() async {
    _isForegroundListening = false;
    try {
      if (_foregroundSpeech.isListening) {
        await _foregroundSpeech.stop();
      }
    } catch (_) {}
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    isShakeSOSActive.value = prefs.getBool('is_shake_active') ?? true;
    isVoiceSOSActive.value = prefs.getBool(_voiceSosPrefsKey) ?? true;
    isEmergencyRecording.value =
        prefs.getBool(_recordingActivePrefsKey) ?? false;
    voiceStatusMessage.value =
        prefs.getString(_voiceStatusPrefsKey) ?? 'Voice SOS disabled';
    recordingStatusMessage.value =
        prefs.getString(_recordingStatusPrefsKey) ?? '';
    lastRecordingPrivatePath.value =
        prefs.getString(_recordingPathPrefsKey) ?? '';
    lastRecordingPublicPath.value =
        prefs.getString(_recordingPublicPathPrefsKey) ?? '';
    generatedMessage = prefs.getString('sos_msg') ?? '';
    selectedSmsSubscriptionId.value = prefs.getInt(
      _preferredSmsSubscriptionPrefsKey,
    );
    isActiveBroadcast.value = prefs.getBool(_sosActivePrefsKey) ?? false;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      await prefs.setString('user_uid', uid);
      try {
        final doc = await FirebaseFirestore.instance
            .collection('active_sos')
            .doc(uid)
            .get();
        if (doc.exists &&
            doc.data()?['active'] == true &&
            doc.data()?['status'] != 'completed') {
          final data = doc.data();
          final startedAtMs = _extractSosTimestampMs(data);
          final isFresh = startedAtMs == null
              ? true
              : DateTime.now().millisecondsSinceEpoch - startedAtMs <=
                    _sosFreshnessWindowMs;

          if (isFresh) {
            isSent.value = true;
            isSosModalVisible.value = false;
            isActiveBroadcast.value = true;
            await prefs.setBool(_sosActivePrefsKey, true);
          } else {
            await FirebaseFirestore.instance
                .collection('active_sos')
                .doc(uid)
                .delete();
            await prefs.setBool(_sosActivePrefsKey, false);
          }
        }
      } catch (e) {
        debugPrint("Failed to restore SOS state: $e");
      }
    }

    final isPending = prefs.getBool(_sosPendingPrefsKey) ?? false;
    if (isPending) {
      final targetTime = prefs.getInt(_sosExecuteAtPrefsKey) ?? 0;
      final remainder =
          ((targetTime - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();

      if (remainder > 0 && remainder <= 10) {
        initiateSOSWorkflow(initialCountdown: remainder);

        WidgetsBinding.instance.addPostFrameCallback((_) {
          // _showCancelDialogAggressive(); // Assumed helper method
        });
      } else {
        await prefs.setBool(_sosPendingPrefsKey, false);
        await prefs.remove(_sosPendingOwnerPrefsKey);
      }
    }

    await refreshSmsSubscriptions();
    await _syncBackgroundMonitoringService();
    if (isVoiceSOSActive.value) {
      _startForegroundVoiceListening();
    }
  }

  Future<void> toggleShakeSOS(bool value) async {
    isShakeSOSActive.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_shake_active', value);

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      await prefs.setString('user_uid', uid);
    }

    if (value) {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
      if (await Permission.locationWhenInUse.isDenied) {
        await Permission.locationWhenInUse.request();
      }
      if (await Permission.locationAlways.isDenied) {
        await Permission.locationAlways.request();
      }
      if (await Permission.ignoreBatteryOptimizations.isDenied) {
        await Permission.ignoreBatteryOptimizations.request();
      }
      if (await Permission.systemAlertWindow.isDenied) {
        await Permission.systemAlertWindow.request();
      }
    }

    await _syncBackgroundMonitoringService();
  }

  Future<void> toggleVoiceSOS(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value) {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
      if (await Permission.locationWhenInUse.isDenied) {
        await Permission.locationWhenInUse.request();
      }
      if (await Permission.locationAlways.isDenied) {
        await Permission.locationAlways.request();
      }
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        isVoiceSOSActive.value = false;
        voiceStatusMessage.value = 'Microphone permission required';
        await prefs.setBool(_voiceSosPrefsKey, false);
        Get.snackbar(
          'Voice SOS Disabled',
          'Microphone permission is required for voice keyword detection.',
          snackPosition: SnackPosition.BOTTOM,
        );
        return;
      }
    }

    isVoiceSOSActive.value = value;
    await prefs.setBool(_voiceSosPrefsKey, value);

    if (value) {
      await _startForegroundVoiceListening();
    } else {
      await _stopForegroundVoiceListening();
      voiceStatusMessage.value = 'Voice SOS disabled';
      isVoiceListening.value = false;
      voiceState.value = 'IDLE';
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      await prefs.setString('user_uid', uid);
    }

    await _syncBackgroundMonitoringService();
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke('setShakeSosEnabled', {'enabled': isShakeSOSActive.value});
      service.invoke('setVoiceSosEnabled', {'enabled': value});
    }
  }

  Future<void> _syncBackgroundMonitoringService() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    final shouldRun =
        isShakeSOSActive.value ||
        isVoiceSOSActive.value ||
        isEmergencyRecording.value ||
        isActiveBroadcast.value;

    if (shouldRun && !isRunning) {
      await service.startService();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } else if (!shouldRun && isRunning) {
      service.invoke("stopService");
      return;
    }

    if (await service.isRunning()) {
      service.invoke('setShakeSosEnabled', {'enabled': isShakeSOSActive.value});
      service.invoke('setVoiceSosEnabled', {'enabled': isVoiceSOSActive.value});
    }
  }

  Future<void> initiateSOSWorkflow({int? initialCountdown}) async {
    if (isLoading.value ||
        isSendingEmergencyAlerts.value ||
        isCountdown.value ||
        isActiveBroadcast.value) {
      Get.snackbar(
        "SOS In Progress",
        "Emergency processing is already running.",
        snackPosition: SnackPosition.BOTTOM,
      );
      return;
    }

    await _stopForegroundVoiceListening();

    final settings = SosSettingsController.instanceOrCreate();
    final prefs = await SharedPreferences.getInstance();
    countdownSeconds.value =
        initialCountdown ?? settings.activationDelaySeconds.value;
    isSent.value = false;
    await prefs.setString(_sosPendingOwnerPrefsKey, 'ui');

    if (Get.currentRoute != '/EmergencySosScreen') {
      Get.to(() => const EmergencySosScreen());
    }

    if (countdownSeconds.value <= 0) {
      isCountdown.value = false;
      await prefs.setBool(_sosPendingPrefsKey, false);
      await prefs.remove(_sosExecuteAtPrefsKey);
      await executeSOS();
      return;
    }

    isCountdown.value = true;
    final executeAt = DateTime.now()
        .add(Duration(seconds: countdownSeconds.value))
        .millisecondsSinceEpoch;
    await prefs.setBool(_sosPendingPrefsKey, true);
    await prefs.setInt(_sosExecuteAtPrefsKey, executeAt);

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (countdownSeconds.value > 1) {
        countdownSeconds.value--;
      } else {
        timer.cancel();
        if (Get.isDialogOpen == true) Get.back();
        executeSOS();
      }
    });
  }

  bool canTriggerSosNow() {
    return !(isLoading.value ||
        isSendingEmergencyAlerts.value ||
        isCountdown.value ||
        isActiveBroadcast.value);
  }

  Future<bool> triggerAutoRouteDeviationSOS({
    required double deviationMeters,
  }) async {
    if (!canTriggerSosNow()) {
      return false;
    }

    await HistoryController.instanceOrCreate().recordJourneyEvent(
      title: 'Auto SOS Triggered',
      subtitle:
          'Route deviation detected at ${deviationMeters.toStringAsFixed(0)}m',
      metadata: {
        'triggerSource': 'auto_route_deviation',
        'deviationMeters': deviationMeters,
      },
    );
    await initiateSOSWorkflow(initialCountdown: 0);
    return true;
  }

  Future<void> cancelSOS() async {
    final settings = SosSettingsController.instanceOrCreate();
    _timer?.cancel();
    isCountdown.value = false;
    countdownSeconds.value = settings.activationDelaySeconds.value;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sosPendingPrefsKey, false);
    await prefs.remove(_sosExecuteAtPrefsKey);
    await prefs.remove(_sosPendingOwnerPrefsKey);

    if (isVoiceSOSActive.value) {
      Future.delayed(const Duration(seconds: 2), () {
        if (isVoiceSOSActive.value && !isCountdown.value && !isSent.value) {
          _startForegroundVoiceListening();
        }
      });
    }
  }

  Future<void> executeSOS() async {
    if (isLoading.value || isActiveBroadcast.value) {
      return;
    }

    isCountdown.value = false;
    isLoading.value = true;
    _resetSmsStatus();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_sosPendingPrefsKey, false);
      await prefs.remove(_sosExecuteAtPrefsKey);
      await prefs.remove(_sosPendingOwnerPrefsKey);

      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null || uid.isEmpty) {
        throw Exception('No active user found.');
      }
      await prefs.setString('user_uid', uid);

      final existingSession = await FirebaseFirestore.instance
          .collection('active_sos')
          .doc(uid)
          .get();
      if (existingSession.exists &&
          existingSession.data()?['active'] == true &&
          existingSession.data()?['status'] != 'completed') {
        isLoading.value = false;
        isSent.value = true;
        isActiveBroadcast.value = true;
        await prefs.setBool(_sosActivePrefsKey, true);
        await _syncBackgroundMonitoringService();
        Get.snackbar(
          'SOS Already Active',
          'Your emergency session is already running.',
          snackPosition: SnackPosition.BOTTOM,
        );
        return;
      }

      final position = await LocationService.getCurrentPosition();
      final lat = position.latitude.toStringAsFixed(6);
      final lng = position.longitude.toStringAsFixed(6);

      final contactCtrl = Get.isRegistered<ContactController>()
          ? Get.find<ContactController>()
          : ContactController.instanceOrCreate();

      final contactsList = await _loadEmergencyContacts(contactCtrl);
      smsTotalCount.value = contactsList.length;

      // Trigger Heavy SOS Vibrations natively
      bool? hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        Vibration.vibrate(pattern: [500, 1000, 500, 1000]);
      }

      // Broadcast SOS to nearby users via Firestore
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final String sessionCategory = Get.isRegistered<JourneyGuardController>() &&
              Get.find<JourneyGuardController>().state.value == JourneyGuardState.activeGuard
          ? 'journey_guard_sos'
          : 'emergency_sos';

      try {
        await FirebaseFirestore.instance.collection('active_sos').doc(uid).set({
          'sessionId': uid,
          'uid': uid,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'sessionCategory': sessionCategory,
          'triggerSource': sessionCategory == 'journey_guard_sos' ? 'journey_guard_deviation' : 'app_button',
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

        Get.snackbar(
          "Broadcast Active",
          "SOS notification dispatched to nearby users.",
          snackPosition: SnackPosition.TOP,
          backgroundColor: Colors.blueAccent,
          colorText: Colors.white,
          duration: const Duration(seconds: 4),
        );
      } catch (e) {
        debugPrint("Error broadcasting SOS: \$e");
      }

      isLoading.value = false;
      isSent.value = true;
      isSosModalVisible.value = true;
      isActiveBroadcast.value = true;
      await prefs.setBool(_sosActivePrefsKey, true);
      await _syncBackgroundMonitoringService();
      final backgroundService = FlutterBackgroundService();
      if (!await backgroundService.isRunning()) {
        await backgroundService.startService();
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      backgroundService.invoke('startSosRecording', {'sessionId': uid});

      final sosId = 'sos_$nowMs';
      await HistoryController.instanceOrCreate().recordSos(
        sosId: sosId,
        status: 'Sent',
        locationLabel: sessionCategory == 'journey_guard_sos'
            ? 'Journey Guard Emergency SOS dispatched'
            : 'Emergency SOS dispatched',
        triggerSource: 'appButton',
      );

      unawaited(
        _dispatchEmergencySmsInBackground(
          contactsList: contactsList,
          contactCtrl: contactCtrl,
          lat: lat,
          lng: lng,
          sessionId: uid,
        ),
      );
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_sosActivePrefsKey, false);
      isLoading.value = false;
      smsStatusMessage.value = 'Emergency sending failed';
      String errorMsg = e.toString().replaceFirst('Exception: ', '');
      Get.snackbar(
        "SOS Failed",
        errorMsg,
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.black87,
        colorText: Colors.redAccent,
        duration: const Duration(seconds: 4),
      );
    }
  }

  Future<List<String>> _loadEmergencyContacts(
    ContactController contactCtrl,
  ) async {
    final contacts = <String>[];
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        if (doc.exists) {
          final data = doc.data() as Map<String, dynamic>;
          for (var i = 1; i <= 4; i++) {
            final value = data['emergencyContact$i'];
            if (value != null && value.toString().trim().isNotEmpty) {
              contacts.add(value.toString().trim());
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Firestore fetch error: $e");
    }

    if (contacts.isEmpty) {
      contacts.addAll(contactCtrl.contacts.map((contact) => contact.trim()));
    }

    return contacts.toSet().where((contact) => contact.isNotEmpty).toList();
  }

  Future<String> _buildSosMessage({
    required String lat,
    required String lng,
    String? sessionId,
  }) async {
    return EmergencyMessageHelper.buildSosMessage(
      lat: lat,
      lng: lng,
      sessionId: sessionId,
    );
  }

  Future<void> _dispatchEmergencySmsInBackground({
    required List<String> contactsList,
    required ContactController contactCtrl,
    required String lat,
    required String lng,
    required String sessionId,
  }) async {
    if (contactsList.isEmpty) {
      smsStatusMessage.value = 'Connecting to emergency contacts...';
      Get.snackbar(
        "Warning",
        "No emergency contacts found.",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.orange,
        colorText: Colors.white,
        duration: const Duration(seconds: 4),
      );
      return;
    }

    final smsGranted = await contactCtrl.checkAndRequestSmsPermission();
    if (!smsGranted) {
      smsStatusMessage.value = 'Trying alternative communication methods...';
      smsRetryStatus.value = 'SMS permission unavailable. Switching channel...';
      debugPrint('[SOS SMS] SEND_SMS permission denied. Triggering fallback.');
      await _triggerAlternativeCommunicationFallback(
        reason: SmsFailureReason.permissionDenied,
        autoShare: true,
      );
      return;
    }

    isSendingEmergencyAlerts.value = true;
    smsStatusMessage.value = 'Sending emergency alerts...';
    await refreshSmsSubscriptions();
    generatedMessage = await _buildSosMessage(
      lat: lat,
      lng: lng,
      sessionId: sessionId,
    );
    await (await SharedPreferences.getInstance()).setString(
      'sos_msg',
      generatedMessage,
    );

    Get.snackbar(
      "Sending SOS...",
      "Automatically notifying emergency contacts...",
      snackPosition: SnackPosition.TOP,
    );

    try {
      final dispatchResult = await _sendAutomaticSmsAlerts(contactsList);
      final failedCount = dispatchResult.failedNumbers.length;
      final sentCount = dispatchResult.sentCount;

      if (failedCount == 0) {
        smsStatusMessage.value = 'Emergency alerts sent successfully';
        Get.snackbar(
          "SOS sent successfully",
          "Messages sent to all $sentCount emergency contacts.",
          snackPosition: SnackPosition.TOP,
          backgroundColor: Colors.green,
          colorText: Colors.white,
        );
      } else if (sentCount > 0) {
        smsStatusMessage.value = 'Contacting help...';
        Get.snackbar(
          "SOS active",
          "Some alerts are still being retried through backup methods.",
          snackPosition: SnackPosition.TOP,
          backgroundColor: Colors.orange,
          colorText: Colors.white,
          duration: const Duration(seconds: 5),
        );
      } else {
        smsStatusMessage.value = 'Trying alternative communication methods...';
        smsRetryStatus.value = 'Switching to backup sharing methods...';
        await _triggerAlternativeCommunicationFallback(
          reason: dispatchResult.lastFailureReason ?? SmsFailureReason.unknown,
          autoShare: true,
        );
      }
    } finally {
      isSendingEmergencyAlerts.value = false;
    }
  }

  Future<_SmsDispatchResult> _sendAutomaticSmsAlerts(
    List<String> contactsList,
  ) async {
    final failedNumbers = <String>[];
    SmsFailureReason? lastFailureReason;
    var sentCount = 0;

    for (var index = 0; index < contactsList.length; index++) {
      final number = contactsList[index];
      smsStatusMessage.value =
          'Sending emergency alerts... ${index + 1}/${contactsList.length}';
      smsRetryStatus.value = 'Sending to ${_maskContact(number)}';
      final outcome = await _sendSOSMessage(number);
      if (outcome.success) {
        sentCount++;
        smsSentCount.value = sentCount;
        smsRetryStatus.value = 'Delivered to ${_maskContact(number)}';
      } else {
        failedNumbers.add(number);
        smsFailedCount.value = failedNumbers.length;
        lastFailureReason = outcome.failureReason;
        smsRetryStatus.value =
            outcome.userFacingStatus ??
            'Trying backup delivery for ${_maskContact(number)}...';
      }

      if (index < contactsList.length - 1) {
        smsRetryStatus.value = 'Waiting before next contact...';
        await Future<void>.delayed(_smsSendGap);
      }
    }

    if (contactsList.isEmpty) {
      smsRetryStatus.value = '';
    }

    return _SmsDispatchResult(
      sentCount: sentCount,
      failedNumbers: failedNumbers,
      lastFailureReason: lastFailureReason,
    );
  }

  Future<_SmsSendOutcome> _sendSOSMessage(String phoneNumber) async {
    if (generatedMessage.isEmpty) {
      return const _SmsSendOutcome(
        success: false,
        failureReason: SmsFailureReason.unknown,
        userFacingStatus: 'Preparing backup communication...',
      );
    }

    final subscriptionIds = _subscriptionIdsToTry();
    SmsFailureReason? lastFailureReason;

    for (var attempt = 1; attempt <= _smsMaxAttemptsPerContact; attempt++) {
      for (
        var index = 0;
        index < subscriptionIds.length && index < _smsMaxSimSwitchesPerAttempt;
        index++
      ) {
        final subscriptionId = subscriptionIds[index];
        try {
          final result = await _sendDirectSmsNative(
            phoneNumber,
            generatedMessage,
            overrideSubscriptionId: subscriptionId,
          );
          if (result.success) {
            if (subscriptionId != null &&
                selectedSmsSubscriptionId.value != subscriptionId) {
              selectedSmsSubscriptionId.value = subscriptionId;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setInt(
                _preferredSmsSubscriptionPrefsKey,
                subscriptionId,
              );
            }
            return const _SmsSendOutcome(success: true);
          }

          lastFailureReason = _classifySmsFailure(result.errorMessage);
          debugPrint(
            "[SOS SMS] Native SMS send failed for ${_maskContact(phoneNumber)} "
            "on attempt $attempt ${subscriptionId == null ? '(default SIM)' : '(SIM $subscriptionId)'}: "
            "${result.errorMessage}",
          );

          if (index < subscriptionIds.length - 1 &&
              _shouldTryAlternateSim(lastFailureReason)) {
            smsRetryStatus.value = 'Trying alternate SMS SIM...';
            continue;
          }
        } catch (e) {
          lastFailureReason = SmsFailureReason.deviceRestriction;
          debugPrint(
            "[SOS SMS] Error sending SMS to ${_maskContact(phoneNumber)} on attempt $attempt: $e",
          );
        }
      }

      if (attempt < _smsMaxAttemptsPerContact) {
        smsRetryStatus.value =
            'Retrying ${_maskContact(phoneNumber)} (${attempt + 1}/$_smsMaxAttemptsPerContact)...';
        await Future<void>.delayed(
          Duration(seconds: _smsRetryGap.inSeconds * (1 << (attempt - 1))),
        );
        continue;
      }
    }

    debugPrint(
      "[SOS SMS] SMS permanently failed for ${_maskContact(phoneNumber)}",
    );
    return _SmsSendOutcome(
      success: false,
      failureReason: lastFailureReason ?? SmsFailureReason.unknown,
      userFacingStatus:
          'Trying backup delivery for ${_maskContact(phoneNumber)}...',
    );
  }

  Future<NativeSmsSendResult> _sendDirectSmsNative(
    String phoneNumber,
    String message, {
    int? overrideSubscriptionId,
  }) async {
    if (!Platform.isAndroid) {
      return const NativeSmsSendResult(
        success: false,
        errorMessage: 'Direct in-app SMS is only supported on Android.',
      );
    }

    try {
      final response = await _smsChannel
          .invokeMethod<Map<dynamic, dynamic>>('sendDirectSms', {
            'phoneNumber': phoneNumber,
            'message': message,
            'subscriptionId':
                overrideSubscriptionId ?? selectedSmsSubscriptionId.value,
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

  Future<void> refreshSmsSubscriptions() async {
    if (!Platform.isAndroid) {
      availableSmsSubscriptions.clear();
      selectedSmsSubscriptionId.value = null;
      return;
    }

    try {
      final response = await _smsChannel.invokeMethod<List<dynamic>>(
        'getSmsSubscriptions',
      );
      final subscriptions = (response ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => SmsSubscriptionInfo.fromMap(item))
          .toList();
      availableSmsSubscriptions.assignAll(subscriptions);

      final selectedId = selectedSmsSubscriptionId.value;
      final hasSelectedMatch =
          selectedId != null &&
          subscriptions.any(
            (subscription) => subscription.subscriptionId == selectedId,
          );
      if (!hasSelectedMatch) {
        SmsSubscriptionInfo? defaultSubscription;
        for (final subscription in subscriptions) {
          if (subscription.isDefault) {
            defaultSubscription = subscription;
            break;
          }
        }
        selectedSmsSubscriptionId.value = defaultSubscription?.subscriptionId;
      }
    } catch (e) {
      debugPrint('Failed to read SMS subscriptions: $e');
      availableSmsSubscriptions.clear();
    }
  }

  Future<void> showSmsSubscriptionPicker() async {
    await refreshSmsSubscriptions();
    if (availableSmsSubscriptions.length <= 1) {
      Get.snackbar(
        'Single SIM Active',
        'Your device is using the default SMS SIM.',
        snackPosition: SnackPosition.BOTTOM,
      );
      return;
    }

    final selectedId = await Get.dialog<int>(
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Choose SMS SIM'),
        content: SizedBox(
          width: double.maxFinite,
          child: Obx(
            () => Column(
              mainAxisSize: MainAxisSize.min,
              children: availableSmsSubscriptions
                  .map(
                    (subscription) => RadioListTile<int>(
                      value: subscription.subscriptionId,
                      groupValue: selectedSmsSubscriptionId.value,
                      onChanged: (value) => Get.back(result: value),
                      title: Text(subscription.displayName),
                      subtitle: Text(subscription.description),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
      ),
    );

    if (selectedId != null) {
      selectedSmsSubscriptionId.value = selectedId;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_preferredSmsSubscriptionPrefsKey, selectedId);
      SmsSubscriptionInfo? selected;
      for (final subscription in availableSmsSubscriptions) {
        if (subscription.subscriptionId == selectedId) {
          selected = subscription;
          break;
        }
      }
      if (selected != null) {
        Get.snackbar(
          'SMS SIM Updated',
          'VIGIL will use ${selected.displayName} for direct SMS.',
          snackPosition: SnackPosition.BOTTOM,
        );
      }
    }
  }

  List<int?> _subscriptionIdsToTry() {
    final ordered = <int?>[];
    final selectedId = selectedSmsSubscriptionId.value;
    if (selectedId != null) {
      ordered.add(selectedId);
    }

    for (final subscription in availableSmsSubscriptions) {
      if (!ordered.contains(subscription.subscriptionId)) {
        ordered.add(subscription.subscriptionId);
      }
    }

    if (ordered.isEmpty) {
      ordered.add(null);
    }

    return ordered;
  }

  SmsFailureReason _classifySmsFailure(String? errorMessage) {
    final message = errorMessage?.toLowerCase() ?? '';
    if (message.contains('permission')) {
      return SmsFailureReason.permissionDenied;
    }
    if (message.contains('no mobile service') ||
        message.contains('no service') ||
        message.contains('radio is off')) {
      return SmsFailureReason.noService;
    }
    if (message.contains('subscription') ||
        message.contains('sim') ||
        message.contains('carrier') ||
        message.contains('slot')) {
      return SmsFailureReason.noSimSelected;
    }
    if (message.contains('generic sms failure') ||
        message.contains('direct sms failed') ||
        message.contains('device')) {
      return SmsFailureReason.deviceRestriction;
    }
    return SmsFailureReason.unknown;
  }

  bool _shouldTryAlternateSim(SmsFailureReason? reason) {
    return reason == SmsFailureReason.noService ||
        reason == SmsFailureReason.noSimSelected ||
        reason == SmsFailureReason.deviceRestriction;
  }

  Future<void> _triggerAlternativeCommunicationFallback({
    required SmsFailureReason reason,
    bool autoShare = false,
  }) async {
    smsStatusMessage.value = 'Trying alternative communication methods...';
    smsRetryStatus.value = _fallbackStatusLabel(reason);
    debugPrint(
      '[SOS SMS] Triggering alternative communication fallback: $reason',
    );

    if (!autoShare || generatedMessage.isEmpty) {
      return;
    }

    try {
      await Share.share(generatedMessage, subject: "URGENT SOS");
    } catch (e) {
      debugPrint('[SOS SMS] Share fallback failed: $e');
    }
  }

  String _fallbackStatusLabel(SmsFailureReason reason) {
    switch (reason) {
      case SmsFailureReason.permissionDenied:
        return 'SMS permission unavailable. Opening backup sharing...';
      case SmsFailureReason.noSimSelected:
        return 'Trying alternate SMS SIM...';
      case SmsFailureReason.noService:
        return 'Network unavailable. Switching communication method...';
      case SmsFailureReason.deviceRestriction:
        return 'Device blocked direct SMS. Opening backup sharing...';
      case SmsFailureReason.unknown:
        return 'Sending via alternative method...';
    }
  }

  String _maskContact(String phoneNumber) {
    if (phoneNumber.length <= 4) {
      return phoneNumber;
    }
    final suffix = phoneNumber.substring(phoneNumber.length - 4);
    return '••••$suffix';
  }

  void _resetSmsStatus() {
    smsStatusMessage.value = 'Preparing emergency alerts...';
    smsRetryStatus.value = '';
    smsSentCount.value = 0;
    smsFailedCount.value = 0;
    smsTotalCount.value = 0;
  }

  Future<void> copyMessage() async {
    if (generatedMessage.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: generatedMessage));
      Get.snackbar(
        "Copied!",
        "Emergency link stored to clipboard.",
        snackPosition: SnackPosition.TOP,
        backgroundColor: Colors.green.shade700,
        colorText: Colors.white,
        duration: const Duration(seconds: 2),
      );
    }
  }

  String get lastRecordingDisplayPath {
    final publicPath = lastRecordingPublicPath.value.trim();
    if (publicPath.isNotEmpty) {
      return publicPath;
    }
    return lastRecordingPrivatePath.value.trim();
  }

  bool get hasLastRecording => lastRecordingDisplayPath.isNotEmpty;

  bool get isLastRecordingPrivateOnly =>
      lastRecordingPublicPath.value.trim().isEmpty &&
      lastRecordingPrivatePath.value.trim().isNotEmpty;

  Future<void> copyLastRecordingPath() async {
    final path = lastRecordingDisplayPath;
    if (path.isEmpty) {
      Get.snackbar(
        'No Recording',
        'No recording available.',
        snackPosition: SnackPosition.BOTTOM,
      );
      return;
    }

    await Clipboard.setData(ClipboardData(text: path));
    Get.snackbar(
      'Path Copied',
      'Recording path copied to clipboard.',
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  Future<void> openLastRecordingFile() async {
    final filePath = await _resolveAccessibleRecordingPath();
    if (filePath == null) {
      _showRecordingUnavailableMessage();
      return;
    }

    try {
      if (Platform.isAndroid) {
        final response = await _smsChannel.invokeMethod<Map<dynamic, dynamic>>(
          'openFile',
          {'path': filePath},
        );
        final data = Map<String, dynamic>.from(response ?? const {});
        if (data['success'] == true) {
          return;
        }
        throw Exception(
          data['errorMessage']?.toString() ?? 'Unable to open recording file.',
        );
      }

      final opened = await launchUrl(
        Uri.file(filePath),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw Exception('Unable to open recording file.');
      }
    } catch (e) {
      Get.snackbar(
        'Open Failed',
        e.toString().replaceFirst('Exception: ', ''),
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  Future<void> shareLastRecordingFile() async {
    final filePath = await _resolveAccessibleRecordingPath();
    if (filePath == null) {
      _showRecordingUnavailableMessage();
      return;
    }

    try {
      await Share.shareXFiles(
        [XFile(filePath)],
        subject: 'VIGIL SOS Recording',
        text: 'SOS audio recording',
      );
    } catch (e) {
      Get.snackbar(
        'Share Failed',
        e.toString().replaceFirst('Exception: ', ''),
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  Future<void> shareSOS() async {
    if (generatedMessage.isNotEmpty) {
      await Share.share(generatedMessage, subject: "URGENT SOS");
    }
  }

  Future<void> shareSafeStatus() async {
    final user = FirebaseAuth.instance.currentUser;
    final safeName = user?.displayName?.trim();
    final name = (safeName != null && safeName.isNotEmpty)
        ? safeName
        : 'The VIGIL user';
    await Share.share(
      '$name is safe now. The SOS has been resolved.',
      subject: 'VIGIL Update',
    );
  }

  void closeAlert() {
    isSent.value = false;
    isSosModalVisible.value = false;
    generatedMessage = '';
  }

  void openSosModal() {
    isSosModalVisible.value = true;
    if (Get.currentRoute != '/EmergencySosScreen') {
      Get.to(() => const EmergencySosScreen());
    }
  }

  Future<void> _clearLocalSosState() async {
    isSent.value = false;
    isSosModalVisible.value = false;
    isActiveBroadcast.value = false;
    isEmergencyRecording.value = false;
    generatedMessage = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sosActivePrefsKey, false);
    await prefs.setBool(_sosPendingPrefsKey, false);
    await prefs.remove(_sosPendingOwnerPrefsKey);
    await prefs.remove(_sosExecuteAtPrefsKey);
    await prefs.setBool(_recordingActivePrefsKey, false);
    await EmergencyDispatchEngine.stopAmbientRecording();
    final backgroundService = FlutterBackgroundService();
    if (await backgroundService.isRunning()) {
      backgroundService.invoke('stopSosRecording');
    }
    await _syncBackgroundMonitoringService();
    SosListenerController.instance.clearActiveNavigation();
  }

  Future<void> stopActiveSOS() async {
    if (isCompletingRescue.value) {
      return;
    }

    isCompletingRescue.value = true;
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        throw Exception('No active user found.');
      }

      final now = DateTime.now();
      final nowMs = now.millisecondsSinceEpoch;
      final sessionRef = FirebaseFirestore.instance
          .collection('active_sos')
          .doc(uid);
      final statsRef = FirebaseFirestore.instance.doc(_globalStatsDocPath);
      final userRef = FirebaseFirestore.instance.collection('users').doc(uid);

      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final sessionSnapshot = await transaction.get(sessionRef);
        if (!sessionSnapshot.exists) {
          return;
        }

        final sessionData = sessionSnapshot.data() ?? <String, dynamic>{};
        final status = sessionData['status']?.toString();
        if (status == 'completed') {
          return;
        }
        if (sessionData['active'] != true || status != 'active') {
          return;
        }

        final victim = sessionData['victim'];
        final hasVictimData =
            (victim is Map && victim['lat'] != null && victim['lng'] != null) ||
            (sessionData['latitude'] != null &&
                sessionData['longitude'] != null);
        if (!hasVictimData) {
          throw Exception(
            'Victim location data is missing for this SOS session.',
          );
        }

        final responders = List<String>.from(
          (sessionData['responders'] as List<dynamic>? ?? []).map(
            (e) => e.toString(),
          ),
        );

        transaction.update(sessionRef, {
          'active': false,
          'status': 'completed',
          'completedAt': FieldValue.serverTimestamp(),
          'completedAtMs': nowMs,
          'completedByUid': uid,
          'updatedAtMs': nowMs,
        });

        transaction.set(statsRef, {
          'totalRescues': FieldValue.increment(1),
          'lastUpdated': FieldValue.serverTimestamp(),
          'lastUpdatedMs': nowMs,
        }, SetOptions(merge: true));

        transaction.set(userRef, {
          'successfulRescuesCount': FieldValue.increment(1),
        }, SetOptions(merge: true));

        for (final responderUid in responders) {
          final responderRef = FirebaseFirestore.instance
              .collection('users')
              .doc(responderUid);
          transaction.set(responderRef, {
            'helpedRescuesCount': FieldValue.increment(1),
          }, SetOptions(merge: true));
        }
      });

      await _clearLocalSosState();

      Get.snackbar(
        "Rescue Completed",
        "Rescue completed successfully.",
        snackPosition: SnackPosition.TOP,
        backgroundColor: Colors.green,
        colorText: Colors.white,
      );
    } catch (e) {
      debugPrint("Error stopping SOS: $e");
      await _clearLocalSosState();
      Get.snackbar(
        "SOS Stopped Locally",
        "The app cleared the emergency session locally. Sync may finish when connectivity returns.",
        backgroundColor: Colors.orange,
        colorText: Colors.white,
      );
    } finally {
      isCompletingRescue.value = false;
    }
  }

  Future<void> updateVictimLocation(Position position) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    try {
      await FirebaseFirestore.instance.collection('active_sos').doc(uid).update(
        {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'victim': {
            'lat': position.latitude,
            'lng': position.longitude,
            'lastUpdated': FieldValue.serverTimestamp(),
            'lastUpdatedMs': nowMs,
          },
          'updatedAtMs': nowMs,
        },
      );
    } catch (e) {
      debugPrint("Failed to update victim location: $e");
    }
  }

  int? _extractSosTimestampMs(Map<String, dynamic>? data) {
    if (data == null) return null;
    final startedAtMs = data['startedAtMs'];
    if (startedAtMs is int) return startedAtMs;

    final updatedAtMs = data['updatedAtMs'];
    if (updatedAtMs is int) return updatedAtMs;

    final timestamp = data['timestamp'];
    if (timestamp is Timestamp) {
      return timestamp.millisecondsSinceEpoch;
    }

    return null;
  }

  Future<String?> _resolveAccessibleRecordingPath() async {
    final candidates = <String>[
      lastRecordingPrivatePath.value.trim(),
      if (_isAbsolutePath(lastRecordingPublicPath.value.trim()))
        lastRecordingPublicPath.value.trim(),
    ].where((path) => path.isNotEmpty);

    for (final path in candidates) {
      if (await File(path).exists()) {
        return path;
      }
    }

    return null;
  }

  bool _isAbsolutePath(String path) {
    if (path.isEmpty) {
      return false;
    }
    return path.startsWith('/') || RegExp(r'^[A-Za-z]:\\').hasMatch(path);
  }

  void _showRecordingUnavailableMessage() {
    final hasDisplayPath = lastRecordingDisplayPath.isNotEmpty;
    Get.snackbar(
      'Recording Unavailable',
      hasDisplayPath
          ? 'Recording path is saved, but the file is not available on this device.'
          : 'No recording available.',
      snackPosition: SnackPosition.BOTTOM,
    );
  }
}

class _SmsDispatchResult {
  const _SmsDispatchResult({
    required this.sentCount,
    required this.failedNumbers,
    this.lastFailureReason,
  });

  final int sentCount;
  final List<String> failedNumbers;
  final SmsFailureReason? lastFailureReason;
}

class _SmsSendOutcome {
  const _SmsSendOutcome({
    required this.success,
    this.failureReason,
    this.userFacingStatus,
  });

  final bool success;
  final SmsFailureReason? failureReason;
  final String? userFacingStatus;
}

class NativeSmsSendResult {
  const NativeSmsSendResult({required this.success, this.errorMessage});

  final bool success;
  final String? errorMessage;
}

enum SmsFailureReason {
  permissionDenied,
  noSimSelected,
  noService,
  deviceRestriction,
  unknown,
}

class SmsSubscriptionInfo {
  const SmsSubscriptionInfo({
    required this.subscriptionId,
    required this.displayName,
    required this.description,
    required this.isDefault,
  });

  factory SmsSubscriptionInfo.fromMap(Map<dynamic, dynamic> map) {
    final displayName = map['displayName']?.toString() ?? 'SIM';
    final carrierName = map['carrierName']?.toString() ?? '';
    final slotIndex = (map['simSlotIndex'] as num?)?.toInt();
    final suffix = slotIndex == null ? '' : ' • Slot ${slotIndex + 1}';
    final description = carrierName.isEmpty
        ? displayName + suffix
        : '$carrierName$suffix';

    return SmsSubscriptionInfo(
      subscriptionId: (map['subscriptionId'] as num).toInt(),
      displayName: displayName,
      description: description,
      isDefault: map['isDefault'] == true,
    );
  }

  final int subscriptionId;
  final String displayName;
  final String description;
  final bool isDefault;
}
