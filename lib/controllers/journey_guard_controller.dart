import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';

import '../services/place_search_service.dart';
import '../services/routing_service.dart';
import '../services/journey_safety_service.dart';
import '../services/safety_geofence_service.dart';
import 'heatmap_controller.dart';
import 'history_controller.dart';
import '../theme/app_colors.dart';

enum JourneyGuardState {
  idle,
  selectDestination,
  routePreview,
  activeGuard,
  completed,
}

enum RouteType {
  safest,
  fastest,
  balanced,
}

class JourneyRouteOption {
  const JourneyRouteOption({
    required this.type,
    required this.title,
    required this.subtitle,
    required this.candidate,
    required this.color,
    required this.isDefault,
  });

  final RouteType type;
  final String title;
  final String subtitle;
  final JourneySafetyCandidate candidate;
  final Color color;
  final bool isDefault;
}

class JourneyGuardController extends GetxController {
  static JourneyGuardController get instance => Get.find<JourneyGuardController>();

  static JourneyGuardController instanceOrCreate() {
    if (Get.isRegistered<JourneyGuardController>()) {
      return Get.find<JourneyGuardController>();
    }
    return Get.put(JourneyGuardController(), permanent: true);
  }

  // Current State
  var state = JourneyGuardState.idle.obs;

  // Search State
  var searchQuery = ''.obs;
  var searchResults = <JourneyDestination>[].obs;
  var isSearching = false.obs;
  var selectedCategoryKey = ''.obs;

  // Destination & Routing State
  var selectedDestination = Rxn<JourneyDestination>();
  var routeOptions = <JourneyRouteOption>[].obs;
  var selectedRouteIndex = 0.obs;
  var isCalculatingRoutes = false.obs;

  // Active Journey Monitoring & Dynamic Live ETA
  var activeSeconds = 0.obs;
  var initialDurationSeconds = 0.obs;
  var initialDistanceMeters = 0.0.obs;
  var remainingDistanceMeters = 0.0.obs;
  var remainingDistanceKmString = '0.0 km'.obs;
  var remainingDurationMinutes = 0.obs;
  var etaArrivalTimeString = '--:-- --'.obs;
  var etaRemainingTimeString = '-- min'.obs;
  var journeyProgressFraction = 0.0.obs;
  var liveSpeedKmh = 0.0.obs;
  var liveSpeedLabel = 'Stationary'.obs;

  var isDeviationDetected = false.obs;
  var deviationDistanceMeters = 0.0.obs;
  var isHighRiskAhead = false.obs;
  var highRiskWarning = ''.obs;

  Timer? _journeyTimer;
  StreamSubscription<Position>? _positionStreamSub;

  @override
  void onClose() {
    _journeyTimer?.cancel();
    _positionStreamSub?.cancel();
    super.onClose();
  }

  /// Enter Destination Selection Mode
  void enterSelectDestinationMode({LatLng? userLocation}) {
    state.value = JourneyGuardState.selectDestination;
    searchQuery.value = '';
    searchResults.clear();
    selectedCategoryKey.value = '';
    selectedDestination.value = null;
    routeOptions.clear();

    if (userLocation != null) {
      // Pre-fetch nearby suggestions when search is empty
      fetchCategoryPlaces('hospital', userLocation);
    }
  }

  /// Cancel Search and Return to Idle Map
  void exitDestinationMode() {
    state.value = JourneyGuardState.idle;
    searchQuery.value = '';
    searchResults.clear();
    selectedDestination.value = null;
    routeOptions.clear();
  }

  /// Trigger debounced place search
  Future<void> onSearchQueryChanged(String query, LatLng? userLocation) async {
    searchQuery.value = query;
    selectedCategoryKey.value = '';

    if (query.trim().isEmpty) {
      if (userLocation != null) {
        fetchCategoryPlaces('hospital', userLocation);
      } else {
        searchResults.clear();
      }
      return;
    }

    isSearching.value = true;
    try {
      final results = await PlaceSearchService.searchPlacesDebounced(query, userLocation);
      searchResults.assignAll(results);
    } catch (e) {
      debugPrint('[JourneyGuard] Search error: $e');
    } finally {
      isSearching.value = false;
    }
  }

  /// Trigger category chip search
  Future<void> fetchCategoryPlaces(String categoryKey, LatLng userLocation) async {
    selectedCategoryKey.value = categoryKey;
    isSearching.value = true;
    try {
      final results = await PlaceSearchService.searchNearbyCategory(categoryKey, userLocation);
      searchResults.assignAll(results);
    } catch (e) {
      debugPrint('[JourneyGuard] Category search error: $e');
    } finally {
      isSearching.value = false;
    }
  }

  /// Select a destination and calculate 3 safety-rated routes
  Future<void> selectDestination(JourneyDestination dest, LatLng startLocation) async {
    selectedDestination.value = dest;
    unawaited(PlaceSearchService.saveRecentSearch(dest));
    state.value = JourneyGuardState.routePreview;
    isCalculatingRoutes.value = true;
    routeOptions.clear();

    try {
      final endLocation = LatLng(dest.latitude, dest.longitude);

      // Fetch alternatives from OSRM
      final osrmRoutes = await RoutingService.getAlternativeRoutes(
        startLocation,
        endLocation,
        maxAlternatives: 3,
      );

      final heatmapCtrl = Get.isRegistered<HeatmapController>() ? Get.find<HeatmapController>() : Get.put(HeatmapController());
      final dangerZones = heatmapCtrl.unsafeZones.toList();

      final candidates = <JourneyRouteOption>[];

      if (osrmRoutes.isNotEmpty) {
        final evaluatedCandidates = <JourneySafetyCandidate>[];
        for (int i = 0; i < osrmRoutes.length; i++) {
          final r = osrmRoutes[i];
          final risk = JourneySafetyService.calculateRouteRisk(
            r.points,
            dangerZones,
          );
          evaluatedCandidates.add(
            JourneySafetyCandidate(
              route: r,
              risk: risk,
              viaPoints: const [],
            ),
          );
        }

        // Use JourneySafetyService to select the safest route avoiding danger zones
        final decision = JourneySafetyService.selectBalancedSafeRoute(
          evaluatedCandidates,
          dangerZones,
        );

        final safestCandidate = decision?.candidate ?? evaluatedCandidates.first;

        // Separate remaining routes for FASTEST and BALANCED options
        final remaining = evaluatedCandidates
            .where((c) => c.route != safestCandidate.route)
            .toList();
        remaining.sort((a, b) => a.route.distanceMeters.compareTo(b.route.distanceMeters));

        final safestOption = JourneyRouteOption(
          type: RouteType.safest,
          title: 'SAFEST',
          subtitle: '${(safestCandidate.route.distanceMeters / 1000).toStringAsFixed(1)} km · ${(safestCandidate.route.durationSeconds / 60).toStringAsFixed(0)} min · Safety ${safestCandidate.risk.score.toStringAsFixed(0)}/100',
          candidate: safestCandidate,
          color: AppColors.safetyGreen,
          isDefault: true,
        );
        candidates.add(safestOption);

        if (remaining.isNotEmpty) {
          final fastestCandidate = remaining.first;
          candidates.add(
            JourneyRouteOption(
              type: RouteType.fastest,
              title: 'FASTEST',
              subtitle: '${(fastestCandidate.route.distanceMeters / 1000).toStringAsFixed(1)} km · ${(fastestCandidate.route.durationSeconds / 60).toStringAsFixed(0)} min · Safety ${fastestCandidate.risk.score.toStringAsFixed(0)}/100',
              candidate: fastestCandidate,
              color: AppColors.softCyan,
              isDefault: false,
            ),
          );
        }

        if (remaining.length > 1) {
          final balancedCandidate = remaining[1];
          candidates.add(
            JourneyRouteOption(
              type: RouteType.balanced,
              title: 'BALANCED',
              subtitle: '${(balancedCandidate.route.distanceMeters / 1000).toStringAsFixed(1)} km · ${(balancedCandidate.route.durationSeconds / 60).toStringAsFixed(0)} min · Safety ${balancedCandidate.risk.score.toStringAsFixed(0)}/100',
              candidate: balancedCandidate,
              color: AppColors.warningAmber,
              isDefault: false,
            ),
          );
        }
      } else {
        // Fallback straight-line route summary
        final fallbackPoints = [startLocation, endLocation];
        final dist = Geolocator.distanceBetween(startLocation.latitude, startLocation.longitude, endLocation.latitude, endLocation.longitude);
        final r = RouteSummary(points: fallbackPoints, distanceMeters: dist, durationSeconds: dist / 10);
        final risk = JourneySafetyService.calculateRouteRisk(fallbackPoints, dangerZones);

        candidates.add(
          JourneyRouteOption(
            type: RouteType.safest,
            title: 'SAFEST',
            subtitle: '${(dist / 1000).toStringAsFixed(1)} km · ${(dist / 600).toStringAsFixed(0)} min · Safety ${risk.score.toStringAsFixed(0)}/100',
            candidate: JourneySafetyCandidate(route: r, risk: risk, viaPoints: const []),
            color: AppColors.safetyGreen,
            isDefault: true,
          ),
        );
      }

      routeOptions.assignAll(candidates);
      selectedRouteIndex.value = 0; // Default to SAFEST ROUTE
    } catch (e) {
      debugPrint('[JourneyGuard] Route calculation error: $e');
    } finally {
      isCalculatingRoutes.value = false;
    }
  }

  JourneyRiskResult _calculateRisk(List<LatLng> points, List<UnsafeZone> dangerZones) {
    if (points.isEmpty || dangerZones.isEmpty) {
      return const JourneyRiskResult(
        score: 94.0,
        nearestDangerDistanceMeters: 9999,
        nearbyDangerCount: 0,
        intersectsDangerZone: false,
      );
    }

    double nearestDanger = 99999;
    int nearbyCount = 0;
    bool intersects = false;

    for (var zone in dangerZones) {
      for (var p in points) {
        final d = Geolocator.distanceBetween(p.latitude, p.longitude, zone.point.latitude, zone.point.longitude);
        if (d < nearestDanger) nearestDanger = d;
        if (d <= 300) nearbyCount++;
        if (d <= 100) intersects = true;
      }
    }

    double penalty = (nearbyCount * 4) + (intersects ? 15 : 0);
    double score = (98.0 - penalty).clamp(50.0, 99.0);

    return JourneyRiskResult(
      score: score,
      nearestDangerDistanceMeters: nearestDanger,
      nearbyDangerCount: nearbyCount,
      intersectsDangerZone: intersects,
    );
  }

  static String _formatTimeOfDay(DateTime time) {
    final hour12 = time.hour == 0 ? 12 : (time.hour > 12 ? time.hour - 12 : time.hour);
    final ampm = time.hour >= 12 ? 'PM' : 'AM';
    final minuteStr = time.minute.toString().padLeft(2, '0');
    return '$hour12:$minuteStr $ampm';
  }

  /// Start Journey Guard Tracking
  void startJourneyGuard() {
    if (selectedDestination.value == null || routeOptions.isEmpty) return;

    state.value = JourneyGuardState.activeGuard;
    activeSeconds.value = 0;
    isDeviationDetected.value = false;
    isHighRiskAhead.value = false;

    _journeyTimer?.cancel();
    _journeyTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      activeSeconds.value++;
    });

    final dest = selectedDestination.value;
    final routeOpt = routeOptions.isNotEmpty ? routeOptions[selectedRouteIndex.value] : null;
    final totalSecs = routeOpt?.candidate.route.durationSeconds.round() ?? 600;
    final totalDist = routeOpt?.candidate.route.distanceMeters ?? 1000;
    final distKm = totalDist / 1000;
    final score = routeOpt?.candidate.risk.score.toInt() ?? 94;

    // Initialize initial ETA & distance baseline
    initialDurationSeconds.value = totalSecs;
    initialDistanceMeters.value = totalDist;
    remainingDistanceMeters.value = totalDist;
    remainingDistanceKmString.value = '${distKm.toStringAsFixed(1)} km';
    final initialMins = (totalSecs / 60).ceil();
    remainingDurationMinutes.value = initialMins;
    etaRemainingTimeString.value = '$initialMins min';
    journeyProgressFraction.value = 0.0;

    final initialArrival = DateTime.now().add(Duration(seconds: totalSecs));
    etaArrivalTimeString.value = _formatTimeOfDay(initialArrival);

    // Register Android Native Geofences (GeofencingClient)
    if (dest != null && routeOpt != null) {
      final geofenceService = Get.isRegistered<SafetyGeofenceService>()
          ? Get.find<SafetyGeofenceService>()
          : Get.put(SafetyGeofenceService(), permanent: true);

      geofenceService.registerJourneyGeofences(
        routePolyline: routeOpt.candidate.route.points,
        destination: LatLng(dest.latitude, dest.longitude),
      );
    }

    try {
      HistoryController.instanceOrCreate().recordJourneyEvent(
        title: 'Journey Guard Active',
        subtitle: 'En route to ${dest?.name ?? "Destination"} (${distKm.toStringAsFixed(1)} km · ETA: ${etaArrivalTimeString.value} · Safety $score/100)',
        metadata: {
          'category': 'Journey Guard',
          'sessionType': 'journey_guard_active',
          'destinationName': dest?.name ?? 'Destination',
          'destinationLat': dest?.latitude,
          'destinationLng': dest?.longitude,
          'distanceMeters': routeOpt?.candidate.route.distanceMeters,
          'eta': etaArrivalTimeString.value,
          'safetyScore': score,
          'routeType': routeOpt?.type.name ?? 'safest',
        },
      );
    } catch (e) {
      debugPrint('Failed to record Journey Guard start: $e');
    }

    Get.snackbar(
      '🛡 JOURNEY GUARD ACTIVE',
      'ETA: ${etaArrivalTimeString.value} ($initialMins min) · Threat monitoring enabled.',
      snackPosition: SnackPosition.TOP,
      backgroundColor: AppColors.safetyGreen,
      colorText: Colors.black,
      duration: const Duration(seconds: 4),
    );
  }

  /// Update live user position during active journey
  void updateLivePosition(LatLng currentPos, {double? speedMs}) {
    if (state.value != JourneyGuardState.activeGuard) return;
    final dest = selectedDestination.value;
    if (dest == null || routeOptions.isEmpty) return;

    final currentRoute = routeOptions[selectedRouteIndex.value].candidate.route;

    // Live speed computation
    if (speedMs != null && speedMs >= 0) {
      final kmh = speedMs * 3.6;
      liveSpeedKmh.value = kmh;
      if (kmh < 1.5) {
        liveSpeedLabel.value = 'Stationary';
      } else if (kmh < 7.0) {
        liveSpeedLabel.value = 'Walking (${kmh.toStringAsFixed(0)} km/h)';
      } else {
        liveSpeedLabel.value = '${kmh.toStringAsFixed(0)} km/h';
      }
    }

    // Remaining distance to destination
    final distToDest = Geolocator.distanceBetween(
      currentPos.latitude,
      currentPos.longitude,
      dest.latitude,
      dest.longitude,
    );
    remainingDistanceMeters.value = distToDest;
    remainingDistanceKmString.value = distToDest < 1000
        ? '${distToDest.toStringAsFixed(0)} m'
        : '${(distToDest / 1000).toStringAsFixed(1)} km';

    // Journey progress fraction (0.0 to 1.0)
    if (initialDistanceMeters.value > 0) {
      final progress = 1.0 - (distToDest / initialDistanceMeters.value);
      journeyProgressFraction.value = progress.clamp(0.0, 1.0);
    }

    // Dynamic ETA calculation adapting to movement speed and remaining distance
    final double effectiveSpeedMs = (liveSpeedKmh.value >= 7.0)
        ? (liveSpeedKmh.value / 3.6)
        : (initialDurationSeconds.value > 0 && initialDistanceMeters.value > 0
            ? (initialDistanceMeters.value / initialDurationSeconds.value)
            : 6.94); // default ~25 km/h urban average

    int dynamicSecs = (distToDest / (effectiveSpeedMs > 0.5 ? effectiveSpeedMs : 6.94)).round();
    if (dynamicSecs < 60 && distToDest > 40) dynamicSecs = 60;

    final minutes = (dynamicSecs / 60).ceil();
    remainingDurationMinutes.value = minutes;
    etaRemainingTimeString.value = '$minutes min';

    final dynamicArrival = DateTime.now().add(Duration(seconds: dynamicSecs));
    etaArrivalTimeString.value = _formatTimeOfDay(dynamicArrival);

    final geofenceService = Get.isRegistered<SafetyGeofenceService>()
        ? Get.find<SafetyGeofenceService>()
        : null;

    // Auto-completion check (< 40 meters from destination OR native Destination Geofence ENTER)
    if (geofenceService?.isDestinationReached.value == true || distToDest <= 40) {
      completeJourney();
      return;
    }

    // Route deviation check (distance to nearest route polyline point > 350m)
    double minPolylineDist = 99999;
    for (var pt in currentRoute.points) {
      final d = Geolocator.distanceBetween(currentPos.latitude, currentPos.longitude, pt.latitude, pt.longitude);
      if (d < minPolylineDist) minPolylineDist = d;
    }

    deviationDistanceMeters.value = minPolylineDist;
    if (minPolylineDist > 350) {
      isDeviationDetected.value = true;
    } else {
      isDeviationDetected.value = false;
    }

    // High Risk Zone Proximity & Geofence Warning Check
    final activeWarning = geofenceService?.activeZoneWarning.value;
    if (activeWarning != null) {
      isHighRiskAhead.value = true;
      highRiskWarning.value =
          'Entered High-Risk Zone "${activeWarning.areaName ?? activeWarning.reason ?? 'Danger Area'}". SafeRoute recommends a detour.';
      return;
    }

    final heatmapCtrl = Get.isRegistered<HeatmapController>() ? Get.find<HeatmapController>() : Get.put(HeatmapController());
    for (var zone in heatmapCtrl.unsafeZones) {
      final d = Geolocator.distanceBetween(currentPos.latitude, currentPos.longitude, zone.point.latitude, zone.point.longitude);
      if (d < 150) {
        isHighRiskAhead.value = true;
        highRiskWarning.value = 'High-risk area detected (${zone.reason ?? "Danger Zone"}). SafeRoute recommends a safer alternative.';
        return;
      }
    }
    isHighRiskAhead.value = false;
  }

  /// Recalculate safer route after deviation or high-risk alert
  Future<void> recalculateSaferRoute(LatLng currentPos) async {
    final dest = selectedDestination.value;
    if (dest == null) return;
    await selectDestination(dest, currentPos);
    isDeviationDetected.value = false;
    isHighRiskAhead.value = false;

    // Refresh native geofences for updated route
    final routeOpt = routeOptions.isNotEmpty ? routeOptions[selectedRouteIndex.value] : null;
    if (routeOpt != null) {
      final geofenceService = Get.isRegistered<SafetyGeofenceService>()
          ? Get.find<SafetyGeofenceService>()
          : Get.put(SafetyGeofenceService(), permanent: true);

      geofenceService.registerJourneyGeofences(
        routePolyline: routeOpt.candidate.route.points,
        destination: LatLng(dest.latitude, dest.longitude),
      );
    }

    Get.snackbar(
      'Route Recalculated',
      'Switched to updated safer route vector & refreshed geofences.',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: AppColors.softCyan,
      colorText: Colors.black,
    );
  }

  /// Complete Journey Guard
  void completeJourney() {
    _journeyTimer?.cancel();
    state.value = JourneyGuardState.completed;

    if (Get.isRegistered<SafetyGeofenceService>()) {
      Get.find<SafetyGeofenceService>().clearAllGeofences();
    }

    final dest = selectedDestination.value;
    final routeOpt = routeOptions.isNotEmpty ? routeOptions[selectedRouteIndex.value] : null;

    final mins = (activeSeconds.value ~/ 60);
    final distKm = (routeOpt?.candidate.route.distanceMeters ?? 0) / 1000;
    final score = routeOpt?.candidate.risk.score.toInt() ?? 94;

    // Record completed journey in HistoryController with rich categorized metadata
    try {
      HistoryController.instanceOrCreate().recordJourneyEvent(
        title: 'Journey Guard Completed',
        subtitle: 'Arrived safely at ${dest?.name ?? "Destination"} (${distKm.toStringAsFixed(1)} km · $mins min · Safety $score/100)',
        metadata: {
          'category': 'Journey Guard',
          'sessionType': 'journey_guard_completed',
          'status': 'Completed',
          'destinationName': dest?.name ?? 'Destination',
          'destinationLat': dest?.latitude,
          'destinationLng': dest?.longitude,
          'distanceKm': distKm.toStringAsFixed(1),
          'durationMinutes': mins,
          'safetyScore': score,
          'routeType': routeOpt?.type.name ?? 'safest',
        },
      );
    } catch (e) {
      debugPrint('Failed to record Journey Guard completion: $e');
    }

    Get.dialog(
      AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Column(
          children: const [
            Icon(Icons.verified, color: AppColors.safetyGreen, size: 48),
            SizedBox(height: 8),
            Text(
              'JOURNEY COMPLETED ✓',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: AppColors.onSurface,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'You arrived safely at ${dest?.name ?? "your destination"}.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.onSurfaceVariant, fontSize: 14),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatItem('Distance', '${distKm.toStringAsFixed(1)} km'),
                  _buildStatItem('Duration', '$mins min'),
                  _buildStatItem('Safety Score', '$score/100'),
                ],
              ),
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.safetyGreen,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                Get.back();
                exitDestinationMode();
              },
              child: const Text('DONE', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
      barrierDismissible: false,
    );
  }

  static Widget _buildStatItem(String label, String value) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppColors.onSurface)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.onSurfaceVariant)),
      ],
    );
  }
}
