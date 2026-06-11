import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../controllers/heatmap_controller.dart';
import 'routing_service.dart';

class JourneyRiskResult {
  const JourneyRiskResult({
    required this.score,
    required this.nearestDangerDistanceMeters,
    required this.nearbyDangerCount,
    required this.intersectsDangerZone,
    this.bufferIntrusionCount = 0,
    this.dangerPenalty = 0,
  });

  final double score;
  final double nearestDangerDistanceMeters;
  final int nearbyDangerCount;
  final bool intersectsDangerZone;
  final int bufferIntrusionCount;
  final double dangerPenalty;
}

class JourneyFloatingOffsets {
  const JourneyFloatingOffsets({
    required this.journeyPanelBottom,
    required this.sosBottom,
    required this.locationBottom,
    required this.riskBottom,
  });

  final double journeyPanelBottom;
  final double sosBottom;
  final double locationBottom;
  final double riskBottom;
}

class JourneySafetyCandidate {
  const JourneySafetyCandidate({
    required this.route,
    required this.risk,
    required this.viaPoints,
  });

  final RouteSummary route;
  final JourneyRiskResult risk;
  final List<LatLng> viaPoints;
}

class JourneyRouteDecision {
  const JourneyRouteDecision({
    required this.candidate,
    required this.detourRatio,
    required this.extraMinutes,
    required this.isFallbackLowestRisk,
    this.warningMessage,
  });

  final JourneySafetyCandidate candidate;
  final double detourRatio;
  final int extraMinutes;
  final bool isFallbackLowestRisk;
  final String? warningMessage;
}

class JourneySafetyService {
  static const double defaultActualZoneRadiusMeters = 150;
  static const double defaultMaxDetourRatio = 1.32;

  static bool doesRouteIntersectDangerZone(
    List<LatLng> route,
    List<UnsafeZone> dangerZones, {
    double bufferMeters = 0,
    double actualZoneRadiusMeters = defaultActualZoneRadiusMeters,
  }) {
    if (route.length < 2 || dangerZones.isEmpty) {
      return false;
    }

    for (final zone in dangerZones) {
      for (var index = 0; index < route.length - 1; index++) {
        final distance = distanceToSegmentMeters(
          zone.point,
          route[index],
          route[index + 1],
        );
        if (distance <= actualZoneRadiusMeters + max(0.0, bufferMeters)) {
          return true;
        }
      }
    }

    return false;
  }

  static double calculateRouteDistance(RouteSummary route) {
    if (route.distanceMeters > 0) {
      return route.distanceMeters;
    }

    if (route.points.length < 2) {
      return 0;
    }

    var total = 0.0;
    for (var index = 0; index < route.points.length - 1; index++) {
      total += Geolocator.distanceBetween(
        route.points[index].latitude,
        route.points[index].longitude,
        route.points[index + 1].latitude,
        route.points[index + 1].longitude,
      );
    }
    return total;
  }

  static double calculateRouteEta(RouteSummary route) {
    return route.durationSeconds;
  }

  static double getAdaptiveDangerBuffer(double zoneSeverity) {
    if (zoneSeverity >= 0.9) {
      return 260;
    }
    if (zoneSeverity >= 0.78) {
      return 140;
    }
    return 80;
  }

  static double getAdaptiveDangerBufferForZone(UnsafeZone zone) {
    return getAdaptiveDangerBuffer(_severityForZone(zone));
  }

  static double calculateDetourRatio(
    RouteSummary candidateRoute,
    RouteSummary shortestRoute,
  ) {
    final shortestDistance = calculateRouteDistance(shortestRoute);
    if (shortestDistance <= 0) {
      return 1;
    }
    return calculateRouteDistance(candidateRoute) / shortestDistance;
  }

  static double calculateDangerZonePenalty(
    RouteSummary route,
    List<UnsafeZone> dangerZones, {
    double actualZoneRadiusMeters = defaultActualZoneRadiusMeters,
  }) {
    return _buildDangerPenaltyResult(
      route.points,
      dangerZones,
      actualZoneRadiusMeters: actualZoneRadiusMeters,
    ).penalty;
  }

  static JourneyRiskResult calculateRouteRisk(
    List<LatLng> route,
    List<UnsafeZone> dangerZones, {
    LatLng? userLocation,
    double dangerBufferMeters = 200,
    double actualZoneRadiusMeters = defaultActualZoneRadiusMeters,
  }) {
    if (route.isEmpty) {
      return const JourneyRiskResult(
        score: 0,
        nearestDangerDistanceMeters: double.infinity,
        nearbyDangerCount: 0,
        intersectsDangerZone: false,
      );
    }

    final dangerPenaltyResult = _buildDangerPenaltyResult(
      route,
      dangerZones,
      actualZoneRadiusMeters: actualZoneRadiusMeters,
      explicitBufferMeters: dangerBufferMeters,
    );

    var score = 0.0;
    if (userLocation != null && dangerZones.isNotEmpty) {
      final nearestToUser = dangerZones
          .map(
            (zone) => Geolocator.distanceBetween(
              userLocation.latitude,
              userLocation.longitude,
              zone.point.latitude,
              zone.point.longitude,
            ),
          )
          .reduce(min);
      score += (1 - (nearestToUser / 1200)).clamp(0.0, 1.0) * 18;
    }

    score += min(dangerPenaltyResult.bufferIntrusionCount * 10, 22).toDouble();
    score += min(dangerPenaltyResult.nearbyDangerCount * 6, 18).toDouble();
    score += min(dangerPenaltyResult.penalty / 5.5, 62);

    if (!dangerPenaltyResult.nearestDangerDistanceMeters.isInfinite) {
      score +=
          (1 - (dangerPenaltyResult.nearestDangerDistanceMeters / 1400)).clamp(
            0.0,
            1.0,
          ) *
          12;
    }

    return JourneyRiskResult(
      score: score.clamp(0, 100).toDouble(),
      nearestDangerDistanceMeters:
          dangerPenaltyResult.nearestDangerDistanceMeters,
      nearbyDangerCount: dangerPenaltyResult.nearbyDangerCount,
      intersectsDangerZone: dangerPenaltyResult.intersectsActualZone,
      bufferIntrusionCount: dangerPenaltyResult.bufferIntrusionCount,
      dangerPenalty: dangerPenaltyResult.penalty,
    );
  }

  static JourneyRouteDecision? selectBalancedSafeRoute(
    List<JourneySafetyCandidate> candidates,
    List<UnsafeZone> dangerZones, {
    double actualZoneRadiusMeters = defaultActualZoneRadiusMeters,
    double maxDetourRatio = defaultMaxDetourRatio,
  }) {
    if (candidates.isEmpty) {
      return null;
    }

    final shortestRoute = [...candidates]
      ..sort(
        (a, b) => calculateRouteDistance(
          a.route,
        ).compareTo(calculateRouteDistance(b.route)),
      );
    final baseline = shortestRoute.first.route;

    final evaluated = candidates.map((candidate) {
      final danger = _buildDangerPenaltyResult(
        candidate.route.points,
        dangerZones,
        actualZoneRadiusMeters: actualZoneRadiusMeters,
      );
      final distanceMeters = calculateRouteDistance(candidate.route);
      final durationSeconds = calculateRouteEta(candidate.route);
      final detourRatio = calculateDetourRatio(candidate.route, baseline);
      final etaRatio = calculateRouteEta(baseline) > 0
          ? durationSeconds / calculateRouteEta(baseline)
          : 1.0;

      var distancePenalty = max(0.0, (detourRatio - 1.05) * 90);
      if (detourRatio > maxDetourRatio) {
        distancePenalty += 35 + ((detourRatio - maxDetourRatio) * 160);
      }

      var etaPenalty = max(0.0, (etaRatio - 1.08) * 75);
      if (etaRatio > maxDetourRatio) {
        etaPenalty += 20 + ((etaRatio - maxDetourRatio) * 110);
      }

      final totalScore =
          danger.penalty +
          distancePenalty +
          etaPenalty +
          candidate.risk.score * 0.6;

      return _EvaluatedJourneyCandidate(
        candidate: candidate,
        danger: danger,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
        detourRatio: detourRatio,
        extraMinutes: max(
          0,
          ((durationSeconds - calculateRouteEta(baseline)) / 60).ceil(),
        ),
        totalScore: totalScore,
      );
    }).toList();

    final nonIntersecting = evaluated
        .where((item) => !item.danger.intersectsActualZone)
        .toList();
    late final _EvaluatedJourneyCandidate chosen;
    if (nonIntersecting.isNotEmpty) {
      nonIntersecting.sort(_compareByShortestRoute);
      final shortestSafe = nonIntersecting.first;
      final practicalSafePool = nonIntersecting
          .where(
            (item) => _isPracticalSafeAlternative(
              item,
              shortestSafe,
              maxDetourRatio: maxDetourRatio,
            ),
          )
          .toList();

      practicalSafePool.sort((a, b) {
        final bufferCompare = a.danger.bufferIntrusionCount.compareTo(
          b.danger.bufferIntrusionCount,
        );
        if (bufferCompare != 0) {
          return bufferCompare;
        }

        final distanceDeltaMeters = (a.distanceMeters - b.distanceMeters).abs();
        if (distanceDeltaMeters > 45) {
          final shortestCompare = _compareByShortestRoute(a, b);
          if (shortestCompare != 0) {
            return shortestCompare;
          }
        }

        final riskCompare = a.candidate.risk.score.compareTo(
          b.candidate.risk.score,
        );
        if (riskCompare != 0) {
          return riskCompare;
        }

        return b.danger.nearestDangerDistanceMeters.compareTo(
          a.danger.nearestDangerDistanceMeters,
        );
      });

      chosen = practicalSafePool.first;
    } else {
      evaluated.sort((a, b) {
        final totalCompare = a.totalScore.compareTo(b.totalScore);
        if (totalCompare != 0) {
          return totalCompare;
        }
        return _compareByShortestRoute(a, b);
      });
      chosen = evaluated.first;
    }

    String? warningMessage;
    final excessiveDetour = chosen.detourRatio > maxDetourRatio;
    if (nonIntersecting.isEmpty) {
      warningMessage =
          'No fully safe route available. Showing lowest-risk route.';
    } else if (excessiveDetour) {
      final plusMinutes = chosen.extraMinutes > 0
          ? '\n+${chosen.extraMinutes} mins due to risk avoidance'
          : '';
      warningMessage = 'Safer route has a longer detour$plusMinutes';
    } else if (chosen.detourRatio > 1.12 ||
        chosen.danger.bufferIntrusionCount > 0) {
      final plusMinutes = chosen.extraMinutes > 0
          ? '\n+${chosen.extraMinutes} mins due to risk avoidance'
          : '';
      warningMessage = 'Safer route selected$plusMinutes';
    }

    return JourneyRouteDecision(
      candidate: chosen.candidate,
      detourRatio: chosen.detourRatio,
      extraMinutes: chosen.extraMinutes,
      isFallbackLowestRisk: nonIntersecting.isEmpty,
      warningMessage: warningMessage,
    );
  }

  static JourneyFloatingOffsets getFloatingButtonOffsets({
    required bool isTripActive,
    required bool hasResponderCard,
    required double screenHeight,
    required double safeBottomPadding,
  }) {
    final compactScreen = screenHeight < 760;
    final journeyPanelHeight = isTripActive
        ? (compactScreen ? 144.0 : 126.0)
        : 116.0;
    final journeyPanelBottom = safeBottomPadding + 16;
    final baseAbovePanel = journeyPanelBottom + journeyPanelHeight + 18;
    final responderLift = hasResponderCard
        ? (compactScreen ? 128.0 : 140.0)
        : 0.0;

    return JourneyFloatingOffsets(
      journeyPanelBottom: journeyPanelBottom,
      sosBottom: baseAbovePanel + responderLift,
      locationBottom: baseAbovePanel + responderLift + 84,
      riskBottom: baseAbovePanel + responderLift + (compactScreen ? 178 : 166),
    );
  }

  static double distanceToSegmentMeters(
    LatLng point,
    LatLng start,
    LatLng end,
  ) {
    final avgLat =
        ((start.latitude + end.latitude + point.latitude) / 3) * pi / 180;
    final metersPerLat = 111320.0;
    final metersPerLng = 111320.0 * cos(avgLat);

    final px = point.longitude * metersPerLng;
    final py = point.latitude * metersPerLat;
    final x1 = start.longitude * metersPerLng;
    final y1 = start.latitude * metersPerLat;
    final x2 = end.longitude * metersPerLng;
    final y2 = end.latitude * metersPerLat;

    final dx = x2 - x1;
    final dy = y2 - y1;
    if (dx == 0 && dy == 0) {
      final deltaX = px - x1;
      final deltaY = py - y1;
      return sqrt(deltaX * deltaX + deltaY * deltaY);
    }

    final t = (((px - x1) * dx) + ((py - y1) * dy)) / ((dx * dx) + (dy * dy));
    final clampedT = t.clamp(0.0, 1.0);
    final projectionX = x1 + (dx * clampedT);
    final projectionY = y1 + (dy * clampedT);
    final deltaX = px - projectionX;
    final deltaY = py - projectionY;
    return sqrt(deltaX * deltaX + deltaY * deltaY);
  }

  static _DangerPenaltyResult _buildDangerPenaltyResult(
    List<LatLng> route,
    List<UnsafeZone> dangerZones, {
    double actualZoneRadiusMeters = defaultActualZoneRadiusMeters,
    double? explicitBufferMeters,
  }) {
    if (route.length < 2 || dangerZones.isEmpty) {
      return const _DangerPenaltyResult(
        penalty: 0,
        nearestDangerDistanceMeters: double.infinity,
        intersectsActualZone: false,
        nearbyDangerCount: 0,
        bufferIntrusionCount: 0,
      );
    }

    var penalty = 0.0;
    var nearestDangerDistance = double.infinity;
    var intersectsActualZone = false;
    var nearbyDangerCount = 0;
    var bufferIntrusionCount = 0;

    for (final zone in dangerZones) {
      final zoneNearest = _nearestDistanceToRoute(route, zone.point);
      final severity = _severityForZone(zone);
      final adaptiveBuffer =
          explicitBufferMeters ?? getAdaptiveDangerBuffer(severity);
      final outerBuffer = actualZoneRadiusMeters + adaptiveBuffer;
      final criticalBuffer = actualZoneRadiusMeters + (adaptiveBuffer * 0.45);

      if (zoneNearest < nearestDangerDistance) {
        nearestDangerDistance = zoneNearest;
      }

      if (zoneNearest <= actualZoneRadiusMeters) {
        intersectsActualZone = true;
        penalty += 1400 + (severity * 300);
        continue;
      }

      if (zoneNearest <= criticalBuffer) {
        bufferIntrusionCount++;
        nearbyDangerCount++;
        final closeness =
            (1 -
                    ((zoneNearest - actualZoneRadiusMeters) /
                        max(criticalBuffer - actualZoneRadiusMeters, 1)))
                .clamp(0.0, 1.0);
        penalty += 180 + (closeness * 110) + (severity * 55);
        continue;
      }

      if (zoneNearest <= outerBuffer) {
        bufferIntrusionCount++;
        nearbyDangerCount++;
        final closeness =
            (1 -
                    ((zoneNearest - criticalBuffer) /
                        max(outerBuffer - criticalBuffer, 1)))
                .clamp(0.0, 1.0);
        penalty += 60 + (closeness * 55) + (severity * 30);
        continue;
      }

      if (zoneNearest <= outerBuffer + 140) {
        nearbyDangerCount++;
        final proximity = (1 - ((zoneNearest - outerBuffer) / 140)).clamp(
          0.0,
          1.0,
        );
        penalty += 10 + (proximity * 18) + (severity * 10);
      }
    }

    return _DangerPenaltyResult(
      penalty: penalty,
      nearestDangerDistanceMeters: nearestDangerDistance,
      intersectsActualZone: intersectsActualZone,
      nearbyDangerCount: nearbyDangerCount,
      bufferIntrusionCount: bufferIntrusionCount,
    );
  }

  static double _nearestDistanceToRoute(List<LatLng> route, LatLng zonePoint) {
    var zoneNearest = double.infinity;
    for (var index = 0; index < route.length - 1; index++) {
      final distance = distanceToSegmentMeters(
        zonePoint,
        route[index],
        route[index + 1],
      );
      if (distance < zoneNearest) {
        zoneNearest = distance;
      }
    }
    return zoneNearest;
  }

  static double _severityForZone(UnsafeZone zone) {
    final normalizedReason = zone.reason?.toLowerCase().trim() ?? '';
    if (normalizedReason.contains('harassment')) {
      return 1.0;
    }
    if (normalizedReason.contains('isolated')) {
      return 0.85;
    }
    if (normalizedReason.contains('lighting')) {
      return 0.65;
    }
    return 0.7;
  }

  static bool _isPracticalSafeAlternative(
    _EvaluatedJourneyCandidate candidate,
    _EvaluatedJourneyCandidate shortestSafe, {
    required double maxDetourRatio,
  }) {
    final baselineDistance = max(shortestSafe.distanceMeters, 1.0);
    final baselineDuration = max(shortestSafe.durationSeconds, 1.0);
    final distanceRatio = candidate.distanceMeters / baselineDistance;
    final durationRatio = candidate.durationSeconds / baselineDuration;
    final distanceDeltaMeters = candidate.distanceMeters - shortestSafe.distanceMeters;
    final durationDeltaSeconds =
        candidate.durationSeconds - shortestSafe.durationSeconds;

    final allowedDistanceRatio = min(maxDetourRatio, 1.12);
    final distanceCloseEnough =
        distanceRatio <= allowedDistanceRatio || distanceDeltaMeters <= 120;
    final durationCloseEnough =
        durationRatio <= 1.15 || durationDeltaSeconds <= 90;

    return distanceCloseEnough && durationCloseEnough;
  }

  static int _compareByShortestRoute(
    _EvaluatedJourneyCandidate a,
    _EvaluatedJourneyCandidate b,
  ) {
    final distanceCompare = a.distanceMeters.compareTo(b.distanceMeters);
    if (distanceCompare != 0) {
      return distanceCompare;
    }

    final durationCompare = a.durationSeconds.compareTo(b.durationSeconds);
    if (durationCompare != 0) {
      return durationCompare;
    }

    return a.candidate.risk.score.compareTo(b.candidate.risk.score);
  }
}

class _DangerPenaltyResult {
  const _DangerPenaltyResult({
    required this.penalty,
    required this.nearestDangerDistanceMeters,
    required this.intersectsActualZone,
    required this.nearbyDangerCount,
    required this.bufferIntrusionCount,
  });

  final double penalty;
  final double nearestDangerDistanceMeters;
  final bool intersectsActualZone;
  final int nearbyDangerCount;
  final int bufferIntrusionCount;
}

class _EvaluatedJourneyCandidate {
  const _EvaluatedJourneyCandidate({
    required this.candidate,
    required this.danger,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.detourRatio,
    required this.extraMinutes,
    required this.totalScore,
  });

  final JourneySafetyCandidate candidate;
  final _DangerPenaltyResult danger;
  final double distanceMeters;
  final double durationSeconds;
  final double detourRatio;
  final int extraMinutes;
  final double totalScore;
}
