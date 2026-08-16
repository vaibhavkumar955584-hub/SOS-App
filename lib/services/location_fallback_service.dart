import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

class LocationResolutionResult {
  final Position? position;
  final String statusLabel;
  final int tierFired; // 1 to 5
  final bool isFallback;

  LocationResolutionResult({
    this.position,
    required this.statusLabel,
    required this.tierFired,
    required this.isFallback,
  });

  String get formattedPayload {
    if (position != null) {
      final lat = position!.latitude.toStringAsFixed(5);
      final lng = position!.longitude.toStringAsFixed(5);
      if (tierFired == 4) {
        return 'Location: Last Known ($lat, $lng) - $statusLabel';
      }
      return 'Location: https://maps.google.com/?q=$lat,$lng ($statusLabel)';
    }
    return 'Location: UNAVAILABLE (Hardware/Network Failed)';
  }
}

class LocationFallbackService {
  static const MethodChannel _platformChannel = MethodChannel('safe_route/sms');

  /// Executes the 5-Tier Location Resolution Fallback Chain
  static Future<LocationResolutionResult> resolveLocationForEmergency() async {
    debugPrint('[LocationFallback] Tier 1: Attempting High Accuracy GPS Fix...');

    // TIER 1: High Accuracy GPS
    try {
      final isServiceEnabled = await Geolocator.isLocationServiceEnabled();
      if (isServiceEnabled) {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
        debugPrint('[LocationFallback] TIER 1 SUCCESS: GPS Fix (${position.latitude}, ${position.longitude})');
        return LocationResolutionResult(
          position: position,
          statusLabel: 'GPS High-Accuracy',
          tierFired: 1,
          isFallback: false,
        );
      }
    } catch (e) {
      debugPrint('[LocationFallback] Tier 1 Failed: $e');
    }

    // TIER 2: Native 1-Tap Resolution via SettingsClient
    debugPrint('[LocationFallback] Tier 2: Invoking Native SettingsClient 1-Tap Prompt...');
    try {
      final Map<dynamic, dynamic>? res = await _platformChannel.invokeMethod('resolveLocationSettings');
      final bool resolutionRequired = res?['resolutionRequired'] == true;
      debugPrint('[LocationFallback] Tier 2 Result: resolutionRequired=$resolutionRequired');

      if (resolutionRequired) {
        await Future.delayed(const Duration(seconds: 2));
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 5),
          ),
        );
        debugPrint('[LocationFallback] TIER 2 SUCCESS: GPS Fix after Resolution');
        return LocationResolutionResult(
          position: position,
          statusLabel: 'GPS System Resolved',
          tierFired: 2,
          isFallback: false,
        );
      }
    } catch (e) {
      debugPrint('[LocationFallback] Tier 2 Resolution Error: $e');
    }

    // TIER 3: Coarse Location (Cell Tower / Wi-Fi)
    debugPrint('[LocationFallback] Tier 3: Attempting Coarse Cell/Wi-Fi Location...');
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 5),
        ),
      );
      debugPrint('[LocationFallback] TIER 3 SUCCESS: Coarse Location Fix (${position.latitude}, ${position.longitude})');
      return LocationResolutionResult(
        position: position,
        statusLabel: 'Coarse Cell/Wi-Fi',
        tierFired: 3,
        isFallback: true,
      );
    } catch (e) {
      debugPrint('[LocationFallback] Tier 3 Coarse Location Failed: $e');
    }

    // TIER 4: Last Known Cached Position with Age Stamp
    debugPrint('[LocationFallback] Tier 4: Attempting Last Known Position Cache...');
    try {
      final lastPosition = await Geolocator.getLastKnownPosition();
      if (lastPosition != null) {
        final ageMinutes = DateTime.now().difference(lastPosition.timestamp).inMinutes;
        final ageString = ageMinutes == 0 ? 'just now' : '$ageMinutes min ago';
        debugPrint('[LocationFallback] TIER 4 SUCCESS: Cached Position ($ageString)');
        return LocationResolutionResult(
          position: lastPosition,
          statusLabel: 'Cached Fix ($ageString)',
          tierFired: 4,
          isFallback: true,
        );
      }
    } catch (e) {
      debugPrint('[LocationFallback] Tier 4 Last Known Position Failed: $e');
    }

    // TIER 5: Location Completely Unavailable Flag
    debugPrint('[LocationFallback] TIER 5: All Location Sources Failed - Setting Location Unavailable Flag.');
    return LocationResolutionResult(
      position: null,
      statusLabel: 'Location Unavailable Flag',
      tierFired: 5,
      isFallback: true,
    );
  }
}
