import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../controllers/heatmap_controller.dart';

class SafetyGeofenceEvent {
  SafetyGeofenceEvent({
    required this.geofenceId,
    required this.transitionType,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
  });

  final String geofenceId;
  final String transitionType; // 'ENTER' or 'EXIT'
  final double latitude;
  final double longitude;
  final int timestamp;
}

class SafetyGeofenceService extends GetxService {
  static SafetyGeofenceService get instance => Get.find<SafetyGeofenceService>();

  static const MethodChannel _channel = MethodChannel('safe_route/geofence');

  final RxInt activeRegisteredCount = 0.obs;
  final RxList<UnsafeZone> registeredZones = <UnsafeZone>[].obs;
  final RxString lastEventLog = 'No events recorded'.obs;
  final Rxn<UnsafeZone> activeZoneWarning = Rxn<UnsafeZone>();
  final RxBool isInsideHighRiskZone = false.obs;
  final RxBool isDestinationReached = false.obs;

  // Deduplication tracker: zoneId_transitionType -> lastTimestampMillis
  final Map<String, int> _lastEventTimestamps = {};
  static const int _deduplicationCooldownMs = 45000; // 45 seconds

  // Stream controller for broadcasting events across app
  final StreamController<SafetyGeofenceEvent> _eventStreamController =
      StreamController<SafetyGeofenceEvent>.broadcast();
  Stream<SafetyGeofenceEvent> get onGeofenceEvent => _eventStreamController.stream;

  @override
  void onInit() {
    super.onInit();
    _channel.setMethodCallHandler(_handleNativeMethodCall);
  }

  /// Entry point for calls coming from Android native GeofenceBroadcastReceiver
  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == 'onGeofenceEvent') {
      final map = Map<String, dynamic>.from(call.arguments as Map);
      final geofenceId = map['geofenceId']?.toString() ?? '';
      final transitionType = map['transitionType']?.toString() ?? 'ENTER';
      final lat = (map['latitude'] as num?)?.toDouble() ?? 0.0;
      final lng = (map['longitude'] as num?)?.toDouble() ?? 0.0;
      final ts = (map['timestamp'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;

      final eventKey = '${geofenceId}_$transitionType';
      final lastTs = _lastEventTimestamps[eventKey] ?? 0;

      // 19. GEOFENCE EVENT DEDUPLICATION: ignore repeat events within 45 seconds
      if (ts - lastTs < _deduplicationCooldownMs) {
        debugPrint('[SafetyGeofenceService] Deduplicated repeated event $eventKey within cooldown window.');
        return;
      }
      _lastEventTimestamps[eventKey] = ts;

      final event = SafetyGeofenceEvent(
        geofenceId: geofenceId,
        transitionType: transitionType,
        latitude: lat,
        longitude: lng,
        timestamp: ts,
      );

      _processGeofenceTransition(event);
    }
  }

  void _processGeofenceTransition(SafetyGeofenceEvent event) {
    final logText = '${event.transitionType} -> ${event.geofenceId} at ${DateTime.now().toIso8601String().substring(11, 19)}';
    lastEventLog.value = logText;
    debugPrint('[SafetyGeofenceService] $logText');

    _eventStreamController.add(event);

    if (event.geofenceId == 'dest_geofence') {
      if (event.transitionType == 'ENTER') {
        isDestinationReached.value = true;
        debugPrint('[SafetyGeofenceService] Destination geofence ENTER confirmed.');
      }
      return;
    }

    final heatmapCtrl = Get.isRegistered<HeatmapController>()
        ? Get.find<HeatmapController>()
        : Get.put(HeatmapController());

    final matchedZone = heatmapCtrl.unsafeZones.firstWhereOrNull(
      (z) => z.id == event.geofenceId || z.id.startsWith(event.geofenceId),
    );

    if (event.transitionType == 'ENTER') {
      isInsideHighRiskZone.value = true;
      if (matchedZone != null) {
        activeZoneWarning.value = matchedZone;
      } else {
        // Fallback synthetic zone if ID format differs
        activeZoneWarning.value = UnsafeZone(
          id: event.geofenceId,
          point: LatLng(event.latitude, event.longitude),
          reason: 'High Risk Area',
          timeStart: '00:00',
          timeEnd: '23:59',
          severityScore: 8.0,
        );
      }
    } else if (event.transitionType == 'EXIT') {
      if (activeZoneWarning.value?.id == event.geofenceId) {
        activeZoneWarning.value = null;
        isInsideHighRiskZone.value = false;
      }
    }
  }

  /// Filter safety zones along journey route corridor (9. DO NOT REGISTER EVERY ZONE)
  List<UnsafeZone> filterCorridorZones({
    required List<LatLng> routePolyline,
    required List<UnsafeZone> allZones,
    double corridorRadiusMeters = 800.0,
  }) {
    if (routePolyline.isEmpty || allZones.isEmpty) return [];

    final List<UnsafeZone> corridorZones = [];

    for (final zone in allZones) {
      bool isNearRoute = false;

      // Sample route polyline every N points for high performance
      final step = (routePolyline.length / 40).clamp(1, 10).toInt();
      for (int i = 0; i < routePolyline.length; i += step) {
        final p = routePolyline[i];
        final dist = Geolocator.distanceBetween(
          p.latitude,
          p.longitude,
          zone.point.latitude,
          zone.point.longitude,
        );

        if (dist <= corridorRadiusMeters) {
          isNearRoute = true;
          break;
        }
      }

      if (isNearRoute) {
        corridorZones.add(zone);
      }
    }

    // Limit to maximum 25 relevant zones to adhere to Android OS bounds
    corridorZones.sort((a, b) => b.severityScore.compareTo(a.severityScore));
    return corridorZones.take(25).toList();
  }

  /// Register geofences natively for active Journey Guard session
  Future<bool> registerJourneyGeofences({
    required List<LatLng> routePolyline,
    required LatLng destination,
    double defaultZoneRadiusMeters = 400.0,
    double destinationRadiusMeters = 150.0,
  }) async {
    try {
      final heatmapCtrl = Get.isRegistered<HeatmapController>()
          ? Get.find<HeatmapController>()
          : Get.put(HeatmapController());

      final corridorZones = filterCorridorZones(
        routePolyline: routePolyline,
        allZones: heatmapCtrl.unsafeZones,
        corridorRadiusMeters: 800.0,
      );

      registeredZones.assignAll(corridorZones);

      final List<Map<String, dynamic>> geofencePayloads = [];

      // 1. Add Danger Zones along route corridor
      for (final zone in corridorZones) {
        geofencePayloads.add({
          'id': zone.id,
          'latitude': zone.point.latitude,
          'longitude': zone.point.longitude,
          'radius': defaultZoneRadiusMeters,
        });
      }

      // 2. Add Special Destination Geofence (26. DESTINATION GEOFENCE)
      geofencePayloads.add({
        'id': 'dest_geofence',
        'latitude': destination.latitude,
        'longitude': destination.longitude,
        'radius': destinationRadiusMeters,
      });

      final result = await _channel.invokeMethod('registerGeofences', {
        'zones': geofencePayloads,
      });

      if (result != null && result['success'] == true) {
        activeRegisteredCount.value = geofencePayloads.length;
        debugPrint('[SafetyGeofenceService] Registered ${geofencePayloads.length} geofences on Android native.');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[SafetyGeofenceService] Geofence registration error: $e');
      return false;
    }
  }

  /// Clear all registered geofences when Journey Guard stops or completes
  Future<void> clearAllGeofences() async {
    try {
      await _channel.invokeMethod('removeAllGeofences');
      activeRegisteredCount.value = 0;
      registeredZones.clear();
      activeZoneWarning.value = null;
      isInsideHighRiskZone.value = false;
      isDestinationReached.value = false;
      _lastEventTimestamps.clear();
      debugPrint('[SafetyGeofenceService] Cleared all Journey Guard geofences.');
    } catch (e) {
      debugPrint('[SafetyGeofenceService] Error clearing geofences: $e');
    }
  }

  @override
  void onClose() {
    _eventStreamController.close();
    super.onClose();
  }
}
