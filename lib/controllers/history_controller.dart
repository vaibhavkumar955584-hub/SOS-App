import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HistoryEntry {
  HistoryEntry({
    required this.sosId,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.timestamp,
    this.triggerSource,
    this.locationLabel,
    this.recordingFilePath,
    this.recordingDurationSeconds,
    this.recordingUploadStatus,
    this.remoteRecordingUrl,
    this.metadata = const {},
  });

  final String sosId;
  final String type;
  final String title;
  final String subtitle;
  final DateTime timestamp;
  final String? triggerSource;
  final String? locationLabel;
  final String? recordingFilePath;
  final int? recordingDurationSeconds;
  final String? recordingUploadStatus; // 'local', 'pending', 'synced'
  final String? remoteRecordingUrl;
  final Map<String, dynamic> metadata;

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    final rawTimestamp = json['timestamp'] as String? ?? '';
    final parsedDate = DateTime.tryParse(rawTimestamp) ?? DateTime.now();
    final fallbackSosId = 'sos_${parsedDate.millisecondsSinceEpoch}';

    return HistoryEntry(
      sosId: json['sosId'] as String? ?? fallbackSosId,
      type: json['type'] as String? ?? 'event',
      title: json['title'] as String? ?? 'Event',
      subtitle: json['subtitle'] as String? ?? '',
      timestamp: parsedDate,
      triggerSource: json['triggerSource'] as String?,
      locationLabel: json['locationLabel'] as String?,
      recordingFilePath: json['recordingFilePath'] as String?,
      recordingDurationSeconds: json['recordingDurationSeconds'] as int?,
      recordingUploadStatus: json['recordingUploadStatus'] as String?,
      remoteRecordingUrl: json['remoteRecordingUrl'] as String?,
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {
        'sosId': sosId,
        'type': type,
        'title': title,
        'subtitle': subtitle,
        'timestamp': timestamp.toIso8601String(),
        'triggerSource': triggerSource,
        'locationLabel': locationLabel,
        'recordingFilePath': recordingFilePath,
        'recordingDurationSeconds': recordingDurationSeconds,
        'recordingUploadStatus': recordingUploadStatus,
        'remoteRecordingUrl': remoteRecordingUrl,
        'metadata': metadata,
      };
}

class HistoryController extends GetxController {
  static HistoryController instanceOrCreate() {
    if (Get.isRegistered<HistoryController>()) {
      return Get.find<HistoryController>();
    }
    return Get.put(HistoryController());
  }

  static const String _prefsKeyPrefix = 'safe_route_history_events';

  final RxList<HistoryEntry> entries = <HistoryEntry>[].obs;
  final RxString query = ''.obs;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  StreamSubscription<User?>? _authSubscription;

  @override
  void onInit() {
    super.onInit();
    loadHistory();
    _authSubscription = _auth.userChanges().listen((_) {
      loadHistory();
    });
  }

  @override
  void onClose() {
    _authSubscription?.cancel();
    super.onClose();
  }

  Future<void> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_resolvedPrefsKey()) ?? [];
    final parsed = raw
        .map(
          (item) =>
              HistoryEntry.fromJson(jsonDecode(item) as Map<String, dynamic>),
        )
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    entries.assignAll(parsed);
    unawaited(autoBindRecordings());
  }

  Future<void> autoBindRecordings() async {
    try {
      final baseDir = await getApplicationSupportDirectory();
      final targetDir = Directory('${baseDir.path}${Platform.pathSeparator}sos_recordings');
      if (!targetDir.existsSync()) return;

      final files = targetDir.listSync().whereType<File>().where((f) => f.path.endsWith('.m4a') && f.lengthSync() > 0).toList();
      if (files.isEmpty) return;

      var updated = false;
      for (final file in files) {
        final filename = file.path.split(Platform.pathSeparator).last;
        int index = entries.indexWhere((e) => e.recordingFilePath == file.path);
        if (index == -1) {
          final fileStat = file.statSync();
          index = entries.indexWhere(
            (e) => e.type == 'sos' && (e.recordingFilePath == null || e.recordingFilePath!.isEmpty) && e.timestamp.difference(fileStat.modified).inMinutes.abs() < 120,
          );
        }

        if (index != -1 && (entries[index].recordingFilePath == null || entries[index].recordingFilePath!.isEmpty)) {
          final existing = entries[index];
          entries[index] = HistoryEntry(
            sosId: existing.sosId,
            type: existing.type,
            title: existing.title,
            subtitle: existing.subtitle,
            timestamp: existing.timestamp,
            triggerSource: existing.triggerSource,
            locationLabel: existing.locationLabel,
            recordingFilePath: file.path,
            recordingDurationSeconds: existing.recordingDurationSeconds ?? 15,
            recordingUploadStatus: existing.recordingUploadStatus ?? 'local',
            remoteRecordingUrl: existing.remoteRecordingUrl,
            metadata: existing.metadata,
          );
          updated = true;
        }
      }

      if (updated) {
        entries.refresh();
        await _save();
      }
    } catch (e) {
      debugPrint('[HistoryController] Auto-bind error: $e');
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final capped = entries.take(50).toList();
    await prefs.setStringList(
      _resolvedPrefsKey(),
      capped.map((entry) => jsonEncode(entry.toJson())).toList(),
    );
  }

  Future<void> addEntry(HistoryEntry entry) async {
    entries.insert(0, entry);
    while (entries.length > 50) {
      entries.removeLast();
    }
    await _save();
  }

  Future<void> recordSos({
    required String sosId,
    required String status,
    String? locationLabel,
    String? triggerSource,
    String? recordingFilePath,
    int? recordingDurationSeconds,
    String? recordingUploadStatus,
    String? remoteRecordingUrl,
  }) async {
    await addEntry(
      HistoryEntry(
        sosId: sosId,
        type: 'sos',
        title: 'SOS $status',
        subtitle: locationLabel ?? 'Emergency alert recorded',
        timestamp: DateTime.now(),
        triggerSource: triggerSource,
        locationLabel: locationLabel,
        recordingFilePath: recordingFilePath,
        recordingDurationSeconds: recordingDurationSeconds,
        recordingUploadStatus: recordingUploadStatus ?? (recordingFilePath != null ? 'local' : null),
        remoteRecordingUrl: remoteRecordingUrl,
      ),
    );
  }

  Future<void> updateSosRecordingInfo({
    required String sosId,
    required String recordingFilePath,
    int? durationSeconds,
    String? uploadStatus,
    String? remoteUrl,
  }) async {
    int index = entries.indexWhere((e) => e.sosId == sosId);
    if (index == -1) {
      // Fallback: match most recent SOS entry in history created in the last 15 minutes
      index = entries.indexWhere(
        (e) => e.type == 'sos' && DateTime.now().difference(e.timestamp).inMinutes < 15,
      );
    }

    if (index != -1) {
      final existing = entries[index];
      entries[index] = HistoryEntry(
        sosId: existing.sosId,
        type: existing.type,
        title: existing.title,
        subtitle: existing.subtitle,
        timestamp: existing.timestamp,
        triggerSource: existing.triggerSource,
        locationLabel: existing.locationLabel,
        recordingFilePath: recordingFilePath,
        recordingDurationSeconds: durationSeconds ?? existing.recordingDurationSeconds,
        recordingUploadStatus: uploadStatus ?? existing.recordingUploadStatus ?? 'local',
        remoteRecordingUrl: remoteUrl ?? existing.remoteRecordingUrl,
        metadata: existing.metadata,
      );
    } else {
      entries.insert(
        0,
        HistoryEntry(
          sosId: sosId,
          type: 'sos',
          title: 'SOS Emergency Recording',
          subtitle: 'Ambient Audio Recorded',
          timestamp: DateTime.now(),
          recordingFilePath: recordingFilePath,
          recordingDurationSeconds: durationSeconds,
          recordingUploadStatus: uploadStatus ?? 'local',
          remoteRecordingUrl: remoteUrl,
        ),
      );
    }
    entries.refresh();
    await _save();
  }

  Future<void> updateSosCloudUploadStatus({
    required String sosId,
    required String uploadStatus,
    required String remoteUrl,
  }) async {
    final index = entries.indexWhere((e) => e.sosId == sosId);
    if (index != -1) {
      final existing = entries[index];
      entries[index] = HistoryEntry(
        sosId: existing.sosId,
        type: existing.type,
        title: existing.title,
        subtitle: existing.subtitle,
        timestamp: existing.timestamp,
        triggerSource: existing.triggerSource,
        locationLabel: existing.locationLabel,
        recordingFilePath: existing.recordingFilePath,
        recordingDurationSeconds: existing.recordingDurationSeconds,
        recordingUploadStatus: uploadStatus,
        remoteRecordingUrl: remoteUrl,
        metadata: existing.metadata,
      );
      entries.refresh();
      await _save();
    }
  }

  Future<void> recordUnsafeZone({
    String? reason,
    String? areaName,
    String? timeStart,
    String? timeEnd,
  }) async {
    final parts = <String>[
      if (reason != null && reason.trim().isNotEmpty) reason,
      if (timeStart != null && timeEnd != null)
        'Unsafe from $timeStart to $timeEnd',
    ];

    final timestamp = DateTime.now();
    await addEntry(
      HistoryEntry(
        sosId: 'unsafe_${timestamp.millisecondsSinceEpoch}',
        type: 'unsafe',
        title: areaName?.trim().isNotEmpty == true
            ? areaName!.trim()
            : 'Unsafe area reported',
        subtitle: parts.isEmpty ? 'Unsafe zone saved' : parts.join(' - '),
        timestamp: timestamp,
        metadata: {
          'reason': reason,
          'areaName': areaName,
          'timeStart': timeStart,
          'timeEnd': timeEnd,
        },
      ),
    );
  }

  Future<void> recordRoute({
    required String destinationName,
    required String distanceLabel,
    required String durationLabel,
  }) async {
    final timestamp = DateTime.now();
    await addEntry(
      HistoryEntry(
        sosId: 'route_${timestamp.millisecondsSinceEpoch}',
        type: 'route',
        title: 'Route to $destinationName',
        subtitle: '$distanceLabel - $durationLabel',
        timestamp: timestamp,
      ),
    );
  }

  Future<void> recordJourneyEvent({
    required String title,
    required String subtitle,
    Map<String, dynamic> metadata = const {},
  }) async {
    final timestamp = DateTime.now();
    await addEntry(
      HistoryEntry(
        sosId: 'journey_${timestamp.millisecondsSinceEpoch}',
        type: 'journey',
        title: title,
        subtitle: subtitle,
        timestamp: timestamp,
        metadata: metadata,
      ),
    );
  }

  Future<void> clearHistory() async {
    entries.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_resolvedPrefsKey());
  }

  String _resolvedPrefsKey() {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      return '${_prefsKeyPrefix}_anonymous';
    }
    return '${_prefsKeyPrefix}_$uid';
  }
}
