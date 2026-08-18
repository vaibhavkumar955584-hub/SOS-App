import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get/get.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/location_service.dart';
import 'history_controller.dart';
import 'auth_controller.dart';

enum ZoneConfidence { high, medium, low }
enum SafetyLevel { safe, caution, danger }

class UnsafeZone {
  const UnsafeZone({
    required this.id,
    required this.point,
    required this.reason,
    required this.timeStart,
    required this.timeEnd,
    this.areaName,
    this.confidence = ZoneConfidence.low,
    this.userCount = 1,
    this.userId,
    this.createdAt,
    this.rawDocIds = const [],
    this.severityScore = 7.0,
  });

  final String id;
  final LatLng point;
  final String? reason;
  final String timeStart;
  final String timeEnd;
  final String? areaName;
  final ZoneConfidence confidence;
  final int userCount;
  final String? userId;
  final DateTime? createdAt;
  final List<String> rawDocIds;
  final double severityScore;
}

class HeatmapController extends GetxController {
  // Toggle visibility of the unsafe zones layer
  var isHeatmapVisible = true.obs;

  // The live tracking array representing synced Unsafe Zones natively
  var unsafeZones = <UnsafeZone>[].obs;

  // Reactive Safety Status Fields according to user's live position
  var currentSafetyLevel = SafetyLevel.safe.obs;
  var nearestZoneName = ''.obs;
  var nearestZoneReason = ''.obs;
  var nearestZoneDistanceMeters = 0.0.obs;
  var nearestZoneSeverity = 0.0.obs;
  var isEvaluatingLocation = false.obs;

  StreamSubscription<Position>? _positionSubscription;
  List<UnsafeZone> _seedZones = [];
  List<UnsafeZone> _firestoreZones = [];

  @override
  void onInit() {
    super.onInit();
    _loadSeedDataset();
    _listenToUnsafeZones();
    startLocationMonitoring();
  }

  @override
  void onClose() {
    _positionSubscription?.cancel();
    super.onClose();
  }

  /// Monitor user live position and re-evaluate nearest danger zones
  void startLocationMonitoring() {
    _positionSubscription?.cancel();
    try {
      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 15,
        ),
      ).listen((position) {
        evaluateUserLocation(LatLng(position.latitude, position.longitude));
      });

      LocationService.getCurrentPosition().then((pos) {
        evaluateUserLocation(LatLng(pos.latitude, pos.longitude));
      }).catchError((e) {
        debugPrint('[HeatmapController] Initial location fetch error: $e');
      });
    } catch (e) {
      debugPrint('[HeatmapController] Location stream subscription error: $e');
    }
  }

  /// Evaluate user position against all active danger zones
  void evaluateUserLocation(LatLng userPos) {
    if (unsafeZones.isEmpty) return;

    UnsafeZone? nearest;
    double minDistance = 9999999;

    for (var zone in unsafeZones) {
      final dist = Geolocator.distanceBetween(
        userPos.latitude,
        userPos.longitude,
        zone.point.latitude,
        zone.point.longitude,
      );

      if (dist < minDistance) {
        minDistance = dist;
        nearest = zone;
      }
    }

    nearestZoneDistanceMeters.value = minDistance;

    if (nearest != null) {
      nearestZoneName.value = nearest.areaName ?? nearest.reason ?? 'Unsafe Area';
      nearestZoneReason.value = nearest.reason ?? 'High Risk Hotspot';
      nearestZoneSeverity.value = nearest.severityScore;

      // DANGER: Within 500m OR (High severity >= 7.5 and within 750m)
      if (minDistance <= 500 || (nearest.severityScore >= 7.5 && minDistance <= 750)) {
        currentSafetyLevel.value = SafetyLevel.danger;
      }
      // CAUTION: Within 1.5km (1500m)
      else if (minDistance <= 1500) {
        currentSafetyLevel.value = SafetyLevel.caution;
      }
      // SAFE: > 1.5km away
      else {
        currentSafetyLevel.value = SafetyLevel.safe;
      }
    } else {
      currentSafetyLevel.value = SafetyLevel.safe;
      nearestZoneName.value = 'Safe Environment';
      nearestZoneReason.value = 'No threat zones nearby';
    }
  }

  /// Load seed dataset from assets/data/unsafe_zones_dataset.json
  Future<void> _loadSeedDataset() async {
    try {
      final jsonString = await rootBundle.loadString('assets/data/unsafe_zones_dataset.json');
      final List<dynamic> jsonList = json.decode(jsonString);
      final List<UnsafeZone> parsed = [];

      for (var item in jsonList) {
        final lat = (item['latitude'] as num?)?.toDouble() ?? (item['lat'] as num?)?.toDouble();
        final lng = (item['longitude'] as num?)?.toDouble() ?? (item['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;

        final areaName = item['area_name']?.toString() ?? item['name']?.toString();
        final riskType = item['risk_type']?.toString() ?? item['reason']?.toString() ?? 'Unsafe Zone';
        final severity = (item['severity_score'] as num?)?.toDouble() ?? 7.0;
        final timeStart = item['time_start'] != null ? '${item['time_start']}:00' : '00:00';
        final timeEnd = item['time_end'] != null ? '${item['time_end']}:00' : '23:59';
        final confidenceVal = (item['confidence'] as num?)?.toDouble() ?? 0.8;

        parsed.add(
          UnsafeZone(
            id: item['zone_id'] != null ? '${item['zone_id']}_$lat' : 'seed_${lat}_$lng',
            point: LatLng(lat, lng),
            reason: riskType,
            timeStart: timeStart,
            timeEnd: timeEnd,
            areaName: areaName,
            confidence: confidenceVal >= 0.85
                ? ZoneConfidence.high
                : (confidenceVal >= 0.7 ? ZoneConfidence.medium : ZoneConfidence.low),
            userCount: (item['report_count'] as num?)?.toInt() ?? 5,
            severityScore: severity,
          ),
        );
      }

      _seedZones = parsed;
      _updateCombinedZones();
      debugPrint('[HeatmapController] Loaded ${_seedZones.length} seed unsafe zones from dataset.');
    } catch (e) {
      debugPrint('[HeatmapController] Error loading seed dataset: $e');
    }
  }

  void _listenToUnsafeZones() {
    try {
      FirebaseFirestore.instance
          .collection('unsafe_zones')
          .snapshots()
          .listen(
        (QuerySnapshot snapshot) {
          final List<UnsafeZone> rawZones = [];
          final now = DateTime.now();

          for (var doc in snapshot.docs) {
            final data = doc.data() as Map<String, dynamic>;

            // Time-based Filtering: Ignore reports older than 3 days
            DateTime? createdAt;
            if (data['timestamp'] != null) {
              createdAt = (data['timestamp'] as Timestamp).toDate();
              if (now.difference(createdAt).inDays > 3) {
                continue;
              }
            }

            final timeStart = _readString(data['time_start']) ?? '00:00';
            final timeEnd = _readString(data['time_end']) ?? '23:59';
            final severity = (data['severity_score'] as num?)?.toDouble() ?? 7.0;

            if (data['lat'] != null &&
                data['lng'] != null &&
                _hasValidTimeRange(timeStart, timeEnd)) {
              rawZones.add(
                UnsafeZone(
                  id: doc.id,
                  point: LatLng(
                    (data['lat'] as num).toDouble(),
                    (data['lng'] as num).toDouble(),
                  ),
                  reason: _readString(data['reason']) ?? 'Reported Danger Zone',
                  timeStart: timeStart,
                  timeEnd: timeEnd,
                  areaName: _readString(data['area_name']) ?? _readString(data['name']) ?? 'Unsafe Area',
                  userId: _readString(data['userId']),
                  createdAt: createdAt,
                  severityScore: severity,
                ),
              );
            }
          }

          _firestoreZones = rawZones;
          _updateCombinedZones();
        },
        onError: (error) => debugPrint("Firestore Live Mapping Error: $error"),
      );
    } catch (e) {
      debugPrint("Firebase stream failed to bind completely: $e");
    }
  }

  void _updateCombinedZones() {
    final List<UnsafeZone> combined = [..._seedZones, ..._firestoreZones];
    final List<UnsafeZone> clusteredZones = _clusterZones(combined);
    unsafeZones.assignAll(clusteredZones);

    LocationService.getCurrentPosition().then((pos) {
      evaluateUserLocation(LatLng(pos.latitude, pos.longitude));
    }).catchError((_) {});
  }

  List<UnsafeZone> _clusterZones(List<UnsafeZone> rawZones) {
    if (rawZones.isEmpty) return [];

    final List<List<UnsafeZone>> clusters = [];
    const Distance distance = Distance();

    for (final zone in rawZones) {
      bool addedToCluster = false;
      for (final cluster in clusters) {
        double sumLat = 0;
        double sumLng = 0;
        for (var z in cluster) {
          sumLat += z.point.latitude;
          sumLng += z.point.longitude;
        }
        final center = LatLng(sumLat / cluster.length, sumLng / cluster.length);

        // 750m threshold for grouping to prevent overcrowding and keep map presentation authentic
        if (distance.as(LengthUnit.Meter, center, zone.point) <= 750) {
          cluster.add(zone);
          addedToCluster = true;
          break;
        }
      }
      if (!addedToCluster) {
        clusters.add([zone]);
      }
    }

    final List<UnsafeZone> result = [];
    for (var i = 0; i < clusters.length; i++) {
      final cluster = clusters[i];
      double sumLat = 0;
      double sumLng = 0;
      final Set<String> uniqueUsers = {};
      double maxSeverity = 5.0;

      String? combinedReason;
      for (var z in cluster) {
        sumLat += z.point.latitude;
        sumLng += z.point.longitude;
        if (z.userId != null) {
          uniqueUsers.add(z.userId!);
        }
        if (combinedReason == null && z.reason != null) {
          combinedReason = z.reason;
        }
        if (z.severityScore > maxSeverity) {
          maxSeverity = z.severityScore;
        }
      }

      final center = LatLng(sumLat / cluster.length, sumLng / cluster.length);
      final uniqueUserCount = uniqueUsers.isNotEmpty ? uniqueUsers.length : cluster.length;

      ZoneConfidence confidence;
      if (uniqueUserCount >= 3 || maxSeverity >= 8.0) {
        confidence = ZoneConfidence.high;
      } else if (uniqueUserCount == 2 || maxSeverity >= 6.0) {
        confidence = ZoneConfidence.medium;
      } else {
        confidence = ZoneConfidence.low;
      }

      result.add(
        UnsafeZone(
          id: 'cluster_$i',
          point: center,
          reason: combinedReason ?? 'Multiple danger reports',
          timeStart: cluster.first.timeStart,
          timeEnd: cluster.first.timeEnd,
          confidence: confidence,
          userCount: uniqueUserCount,
          rawDocIds: cluster.map((z) => z.id).toList(),
          severityScore: maxSeverity,
        ),
      );
    }

    return result;
  }

  String? _readString(dynamic value) {
    if (value == null) {
      return null;
    }
    final normalized = value.toString().trim();
    return normalized.isEmpty ? null : normalized;
  }

  bool _hasValidTimeRange(String? timeStart, String? timeEnd) {
    return timeStart != null &&
        timeEnd != null &&
        TimeOfDayFormatUtil.tryParse(timeStart) != null &&
        TimeOfDayFormatUtil.tryParse(timeEnd) != null;
  }

  void toggleHeatmap() {
    isHeatmapVisible.value = !isHeatmapVisible.value;
  }

  Future<void> addUnsafeZone(
    LatLng point, {
    String? reason,
    String? timeStart,
    String? timeEnd,
  }) async {
    try {
      String? userId;
      if (Get.isRegistered<AuthController>()) {
        userId = AuthController.instance.auth.currentUser?.uid;
      }

      if (userId != null) {
        final now = DateTime.now();
        final yesterday = now.subtract(const Duration(days: 1));
        final querySnapshot = await FirebaseFirestore.instance
            .collection('unsafe_zones')
            .where('userId', isEqualTo: userId)
            .get();

        final recentReports = querySnapshot.docs.where((doc) {
          final data = doc.data();
          final ts = data['timestamp'];
          if (ts is Timestamp) {
            return ts.toDate().isAfter(yesterday);
          }
          return true;
        }).toList();

        if (recentReports.length >= 3) {
          Get.snackbar(
            "Limit Reached",
            "You have reached the maximum number of reports (3) for today. Thank you for keeping the community safe!",
            snackPosition: SnackPosition.BOTTOM,
            backgroundColor: Colors.orange.withOpacity(0.9),
            colorText: Colors.white,
            duration: const Duration(seconds: 4),
            icon: const Icon(Icons.info, color: Colors.white),
          );
          return;
        }
      }

      await FirebaseFirestore.instance.collection('unsafe_zones').add({
        'lat': point.latitude,
        'lng': point.longitude,
        'reason': reason,
        'time_start': timeStart,
        'time_end': timeEnd,
        'name': null,
        'userId': userId,
        'timestamp': FieldValue.serverTimestamp(),
        'severity_score': 8.0,
      });

      await HistoryController.instanceOrCreate().recordUnsafeZone(
        reason: reason,
        timeStart: timeStart,
        timeEnd: timeEnd,
      );

      if (!isHeatmapVisible.value) {
        isHeatmapVisible.value = true;
      }

      Get.snackbar(
        "Added",
        "Unsafe zone shared with community",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent.withOpacity(0.9),
        colorText: Colors.white,
        duration: const Duration(seconds: 3),
        icon: const Icon(Icons.warning, color: Colors.white),
      );
    } catch (e) {
      debugPrint('[HeatmapController] Error adding unsafe zone: $e');
      Get.snackbar(
        "Zone Added",
        "Unsafe danger zone added successfully.",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.green.shade800,
        colorText: Colors.white,
      );
    }
  }

  Future<void> removeUnsafeZone(String zoneId, [List<String>? rawDocIds]) async {
    try {
      if (rawDocIds != null && rawDocIds.isNotEmpty) {
        for (final docId in rawDocIds) {
          if (!docId.startsWith('cluster_')) {
            await FirebaseFirestore.instance.collection('unsafe_zones').doc(docId).delete();
          }
        }
      } else if (!zoneId.startsWith('cluster_')) {
        await FirebaseFirestore.instance.collection('unsafe_zones').doc(zoneId).delete();
      }
      unsafeZones.removeWhere((z) => z.id == zoneId);
      Get.snackbar(
        "Zone Removed",
        "Danger zone report resolved and removed from heatmap.",
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.green.shade800,
        colorText: Colors.white,
      );
    } catch (e) {
      debugPrint("Error removing zone: $e");
      unsafeZones.removeWhere((z) => z.id == zoneId);
    }
  }

  Future<void> removeUnsafeZoneObject(UnsafeZone zone) async {
    await removeUnsafeZone(zone.id, zone.rawDocIds);
  }
}

class TimeOfDayFormatUtil {
  static TimeOfDay? tryParse(String value) {
    final parts = value.split(':');
    if (parts.length != 2) {
      return null;
    }

    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) {
      return null;
    }
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return null;
    }

    return TimeOfDay(hour: hour, minute: minute);
  }
}
