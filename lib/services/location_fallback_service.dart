import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

class LocationResolutionResult {
  final Position? position;
  final String statusLabel;
  final int tierFired; // 1 to 6
  final bool isFallback;
  final String? regionHint; // SIM-based or IP-based region hint

  LocationResolutionResult({
    this.position,
    required this.statusLabel,
    required this.tierFired,
    required this.isFallback,
    this.regionHint,
  });

  String get formattedPayload {
    if (position != null) {
      final lat = position!.latitude.toStringAsFixed(5);
      final lng = position!.longitude.toStringAsFixed(5);
      if (tierFired == 4) {
        return 'Location: Last Known ($lat, $lng) - $statusLabel\nhttps://maps.google.com/?q=$lat,$lng';
      }
      if (tierFired == 5) {
        return 'Location: Estimated IP/Cell ($lat, $lng) - $statusLabel\nhttps://maps.google.com/?q=$lat,$lng';
      }
      return 'Location ($statusLabel):\nhttps://maps.google.com/?q=$lat,$lng';
    }
    if (regionHint != null && regionHint!.isNotEmpty) {
      return 'Location: Approximate region — Carrier: $regionHint ($statusLabel)';
    }
    return 'Location: No location available (GPS/Network Disabled)';
  }
}

class LocationFallbackService {
  static const MethodChannel _platformChannel = MethodChannel('safe_route/sms');

  /// Executes the 6-Tier Location Resolution Fallback Chain:
  /// Tier 1: High Accuracy Hardware GPS Fix (Satellite)
  /// Tier 2: Native SettingsClient 1-Tap Location Prompt
  /// Tier 3: Coarse Location Provider (Cell Tower / Wi-Fi Network)
  /// Tier 4: Last Known System Position Cache with timestamp age
  /// Tier 5: Cell Network Carrier (SIM/MCC-MNC) & IP-Based Geolocation
  /// Tier 6: Location Completely Unavailable Flag
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

    // TIER 5: SIM Carrier Operator & Public IP Geolocation Fallback
    debugPrint('[LocationFallback] Tier 5: Attempting Cell Network Carrier & IP Geolocation...');
    try {
      // 5a. Query IP Geolocation API if network connection is active
      final ipLocation = await _fetchIpLocation();
      if (ipLocation != null) {
        final double lat = ipLocation['lat'];
        final double lng = ipLocation['lng'];
        final String label = ipLocation['label'];
        debugPrint('[LocationFallback] TIER 5 SUCCESS: IP Geolocation ($lat, $lng - $label)');
        return LocationResolutionResult(
          position: Position(
            longitude: lng,
            latitude: lat,
            timestamp: DateTime.now(),
            accuracy: 5000.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
          ),
          statusLabel: 'Estimated via IP ($label)',
          tierFired: 5,
          isFallback: true,
          regionHint: label,
        );
      }

      // 5b. Query Native SIM Carrier info via TelephonyManager
      final Map<dynamic, dynamic>? telInfo = await _platformChannel.invokeMethod('getTelephonyNetworkInfo');
      if (telInfo != null && telInfo['success'] == true) {
        final String networkOp = telInfo['networkOperatorName'] ?? '';
        final String simOp = telInfo['simOperatorName'] ?? '';
        final String countryIso = telInfo['simCountryIso'] ?? telInfo['networkCountryIso'] ?? '';
        final carrierHint = [simOp.isNotEmpty ? simOp : networkOp, countryIso].where((s) => s.isNotEmpty).join(' ');
        if (carrierHint.isNotEmpty) {
          debugPrint('[LocationFallback] TIER 5 CARRIER HINT: $carrierHint');
          return LocationResolutionResult(
            position: null,
            statusLabel: 'SIM Carrier Info',
            tierFired: 5,
            isFallback: true,
            regionHint: carrierHint,
          );
        }
      }
    } catch (e) {
      debugPrint('[LocationFallback] Tier 5 Error: $e');
    }

    // TIER 6: Location Completely Unavailable Flag
    debugPrint('[LocationFallback] TIER 6: All Location Sources Failed - Setting Location Unavailable Flag.');
    return LocationResolutionResult(
      position: null,
      statusLabel: 'Location Unavailable Flag',
      tierFired: 6,
      isFallback: true,
    );
  }

  static Future<Map<String, dynamic>?> _fetchIpLocation() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client.getUrl(Uri.parse('https://ipapi.co/json/'));
      final response = await request.close().timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final data = json.decode(body) as Map<String, dynamic>;
        final lat = (data['latitude'] as num?)?.toDouble();
        final lng = (data['longitude'] as num?)?.toDouble();
        final city = data['city'] as String? ?? '';
        final region = data['region'] as String? ?? '';
        final country = data['country_name'] as String? ?? '';
        if (lat != null && lng != null) {
          return {
            'lat': lat,
            'lng': lng,
            'label': [city, region, country].where((s) => s.isNotEmpty).join(', '),
          };
        }
      }
    } catch (e) {
      debugPrint('[LocationFallback] IP Geolocation lookup error: $e');
    }
    return null;
  }
}
