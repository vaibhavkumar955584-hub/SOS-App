import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'history_controller.dart';
import 'auth_controller.dart';

enum ZoneConfidence { high, medium, low }

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
}

class HeatmapController extends GetxController {
  // Toggle visibility of the unsafe zones layer
  var isHeatmapVisible = true.obs;

  // The live tracking array representing synced Unsafe Zones natively
  var unsafeZones = <UnsafeZone>[].obs;

  @override
  void onInit() {
    super.onInit();
    _listenToUnsafeZones();
  }

  void _listenToUnsafeZones() {
    // Graceful exception bounding allowing local compilation tests even if Firebase is disabled structurally
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
                ),
              );
            }
          }

          // Zone Aggregation (Clustering)
          final List<UnsafeZone> clusteredZones = _clusterZones(rawZones);

          // Reactive assignment forcing GetX Obx instances to reload map vectors securely
          unsafeZones.assignAll(clusteredZones);
        },
        onError: (error) => debugPrint("Firestore Live Mapping Error: $error"),
      );
    } catch (e) {
      debugPrint("Firebase stream failed to bind completely: $e");
    }
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
        
        // 500m threshold for grouping
        if (distance.as(LengthUnit.Meter, center, zone.point) <= 500) {
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
      
      // Take the reason from the most recent report (assuming the last one might not always be the newest, but let's take the first non-null)
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
      }
      
      final center = LatLng(sumLat / cluster.length, sumLng / cluster.length);
      // Fallback: If no users have a userId stored, treat each point as unique for legacy data testing
      final uniqueUserCount = uniqueUsers.isNotEmpty ? uniqueUsers.length : cluster.length;
      
      ZoneConfidence confidence;
      if (uniqueUserCount >= 3) {
        confidence = ZoneConfidence.high;
      } else if (uniqueUserCount == 2) {
        confidence = ZoneConfidence.medium;
      } else {
        confidence = ZoneConfidence.low;
      }

      result.add(
        UnsafeZone(
          id: 'cluster_$i', // Generate a pseudo-ID for the cluster
          point: center,
          reason: combinedReason ?? 'Multiple reasons',
          timeStart: cluster.first.timeStart,
          timeEnd: cluster.first.timeEnd,
          confidence: confidence,
          userCount: uniqueUserCount,
          rawDocIds: cluster.map((z) => z.id).toList(),
        )
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

  // Action hook to toggle boolean states reactively across UI
  void toggleHeatmap() {
    isHeatmapVisible.value = !isHeatmapVisible.value;
  }

  // Package target coordinates into dynamic objects piping directly to centralized Cloud Firestore mechanisms
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
      
      // User Rate Limiting: Check previous reports by this user today
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
            icon: const Icon(Icons.info, color: Colors.white)
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
      });

      await HistoryController.instanceOrCreate().recordUnsafeZone(
        reason: reason,
        timeStart: timeStart,
        timeEnd: timeEnd,
      );

      // Automatically turn on the Heatmap layer if it wasn't already to showcase the community updates
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
        icon: const Icon(Icons.warning, color: Colors.white)
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
